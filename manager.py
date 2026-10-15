#!/usr/bin/env python3
"""Native manager backend. stdout carries small JSON results only."""
import fcntl, json, os, plistlib, shlex, shutil, subprocess, sys, tempfile, uuid
from pathlib import Path
import profile_store as store
import desktop_sync as sync
import profile_health
import sync_transaction
from backend_protocol import BackendError, VERSION, FEATURES, envelope, encode
from safe_io import atomic_write, private_dir, digest, fsync_dir

ROOT=store.ROOT
SOURCE=Path('/Applications/Claude.app')

def configure():
    sync.ROOT=ROOT
    profiles=store.load(); ready={}; pending=[]
    for p in profiles:
        try: ready[p['id']]=store.account(p)
        except (OSError,ValueError,KeyError,TypeError,AttributeError) as e: pending.append(p['name']+': '+str(e))
    selected={p['id']:p for p in profiles if p['id'] in ready}
    sync.PREFLIGHT_NAMES={i:p['name'] for i,p in selected.items()}
    sync.NAMES={i:p['name'] for i,p in selected.items() if p.get('syncEnabled', False)}
    sync.gui=lambda i:store.gui(selected[i])
    sync.account_dir=lambda i:ready[i]
    sync.PROFILE_MODELS={i:p['model'] for i,p in selected.items()}
    sync.running_profiles=lambda:running(profiles)
    sync.HISTORY_ROOTS=[]; sync.DESKTOP_ROOTS=[]; sync.EXTERNAL_TARGETS={}
    binding = {i: str(ready[i]) for i in sync.NAMES}
    def validate_binding():
        current=store.load()
        chosen={p['id'] for p in current if p.get('syncEnabled',False) and p['id'] in ready}
        if chosen!=set(binding): raise ValueError('Sync selection changed; retry.')
        for p in current:
            if p['id'] in binding:
                if str(store.account(p))!=binding[p['id']]: raise ValueError('Account/organization changed; retry.')
                faults=[i for i in profile_health.inspect_profile(p) if i['blocking']]
                if faults: raise ValueError(p['name']+': '+faults[0]['detail'])
    sync.BINDING_VALIDATOR=validate_binding
    return profiles,pending

def running(profiles):
    if not profiles: return []
    lines = sync.processes()
    return [p['id'] for p in profiles if any(line.startswith(p['bundle']+'/Contents/MacOS/Claude.bin') for line in lines)]


def select_profile(profile_id, enabled):
    private_dir(ROOT)
    with (ROOT/'registry.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        profiles = store.load()
        p = next((p for p in profiles if p['id'] == profile_id), None)
        if p is None: raise BackendError('profile_missing')
        p['syncEnabled'] = enabled
        store.save(profiles)
    return {'selected': enabled}


def status():
    profiles,pending=configure(); running=sync.running_profiles(); result=[]
    for p in profiles:
        try: store.account(p); ready=True
        except (OSError, ValueError, KeyError, TypeError): ready=False
        count=0; archived=0
        if ready:
            for f in store.account(p).parent.glob('*/local_*.json'):
                if (f.parent/('deleted_'+f.stem.removeprefix('local_'))).exists():continue
                count+=1
                try:
                    record=json.loads(f.read_text()); archived+=bool(record.get('isArchived',record.get('archived',False)))
                except (OSError, ValueError, AttributeError):pass
        result.append({**{k:v for k,v in p.items() if k!='legacyAccount'},'syncEnabled':p.get('syncEnabled',False),'ready':ready,'running':p['id'] in running,'sessions':count,'archived':archived,
                       'health':profile_health.inspect_profile(p)})
    last=None
    try:
        if (ROOT/'last-sync.json').exists():
            last=json.loads((ROOT/'last-sync.json').read_text())
            if (not isinstance(last, dict)
                    or any(type(last.get(k)) is not int or last[k] < 0 for k in ('profiles','sessions','newBranches','filesChanged'))
                    or not isinstance(last.get('backup'),str)
                    or (last.get('warnings') is not None and (type(last['warnings']) is not int or last['warnings'] < 0))
                    or (last.get('pending') is not None and (not isinstance(last['pending'],list) or any(not isinstance(p,str) for p in last['pending'])))):
                raise ValueError('Invalid sync report')
    except (OSError,ValueError):
        last=None; pending.append('Báo cáo cũ bị lỗi; profile vẫn có thể sử dụng.')
    return {'profiles':result,'pending':pending,'lastSync':last,'issues':recovery_issues()}


def recovery_issues():
    """Read-only recovery summary; never include journal contents or private paths."""
    issues=[]
    try:
        if sync_transaction.pending(ROOT):
            issues.append({'code':'pending_recovery','blocking':True,'detail':'Có lượt đồng bộ chưa hoàn tất. Đóng các profile rồi phục hồi.'})
        path=ROOT/'clone-repair.json'
        if path.exists() and json.loads(path.read_text()).get('state')=='active':
            issues.append({'code':'interrupted_clone_repair','blocking':True,'detail':'Có lượt sửa clone chưa hoàn tất. Đóng các profile rồi phục hồi.'})
    except (OSError,ValueError,TypeError,AttributeError,KeyError):
        issues.append({'code':'recovery_unreadable','blocking':True,'detail':'Không đọc được nhật ký phục hồi. Giữ lại bản sao lưu và kiểm tra dữ liệu.'})
    return issues

def recover_clone_repair():
    path=ROOT/'clone-repair.json'
    if not path.exists(): return
    journal=json.loads(path.read_text())
    if journal.get('state')!='active': return
    target=Path(journal['target']); backup=Path(journal['backup']); previous=journal['previous']
    if str(target)!=previous['bundle'] or backup.parent!=target.parent or not backup.name.startswith(target.name+'.harbor-backup-'):
        raise ValueError('Invalid clone repair journal')
    if backup.exists():
        if target.exists(): os.rename(target,target.with_name(target.name+'.harbor-incomplete-'+uuid.uuid4().hex))
        os.rename(backup,target); fsync_dir(target.parent)
    profiles=store.load()
    store.save([previous if p['id']==previous['id'] else p for p in profiles])
    journal['state']='rolled_back'; atomic_write(path,sync.json_bytes(journal))


def doctor():
    issues=recovery_issues()
    for p in store.load(): issues.extend(profile_health.inspect_profile(p,verify_signature=True))
    return {'issues':issues,'ok':not any(i['blocking'] for i in issues)}


def require_idle_import_source(root, desktop_root=None):
    """Conservatively reject visible writers/live sessions, including pauses between writes.

    This is an admission check, not a cooperative lock on third-party tools.
    Snapshot validation still checks source bytes before transaction commit.
    """
    root=Path(root).resolve()
    roots=[root, *([Path(desktop_root).resolve()] if desktop_root else [])]
    def references_source(word):
        value=word.split('=',1)[-1]
        if not value.startswith('/'): return False
        return any(Path(value).resolve().is_relative_to(folder) for folder in roots)
    session_ids={p.stem for p in (root/'projects').glob('*/*.jsonl')}
    for line in sync.processes():
        try: words=shlex.split(line)
        except ValueError: continue
        if not words: continue
        executable=Path(words[0]).name.lower()
        is_claude=executable in ('claude','claude.bin') or (
            executable in ('node','bun') and any('claude-code' in w for w in words[1:3]))
        if not is_claude: continue
        if (root == (Path.home()/'.claude').resolve()
                or any(references_source(w) for w in words[1:])
                or any(sid in line for sid in session_ids)):
            raise BackendError('import_source_busy')
    for folder in roots:
        try:
            check=subprocess.run(['/usr/sbin/lsof','-n','-P','-F','a','+D',str(folder)],
                                 capture_output=True,text=True,timeout=15)
        except (OSError,subprocess.TimeoutExpired):
            raise BackendError('import_source_unchecked') from None
        if check.returncode not in (0,1) or check.stderr.strip():
            raise BackendError('import_source_unchecked')
        if any(line in ('aw','au') for line in check.stdout.splitlines()):
            raise BackendError('import_source_busy')


def import_history(arguments):
    import argparse
    parser=argparse.ArgumentParser(prog='manager.py import')
    parser.add_argument('--source',required=True,help='Explicit Claude Code configuration root')
    parser.add_argument('--to',required=True,help='Comma-separated selected target profile IDs')
    parser.add_argument('--desktop-root',help='Optional matching Desktop data root for prior-chain metadata')
    args=parser.parse_args(arguments)
    profiles,pending=configure(); targets=set(args.to.split(','))
    if not targets or not targets <= set(sync.NAMES): raise ValueError('Targets must be selected and initialized profiles')
    root=Path(args.source).expanduser().resolve()
    if not (root/'projects').is_dir(): raise ValueError('Source has no projects directory')
    if any(root == sync.code(p).resolve() for p in sync.NAMES): raise ValueError('Use sync for managed sources')
    sync.NAMES={p:sync.NAMES[p] for p in targets}
    desktop_root=Path(args.desktop_root).expanduser().resolve() if args.desktop_root else None
    if desktop_root and not desktop_root.is_dir(): raise ValueError('Desktop metadata root is not a directory')
    binding_validator=sync.BINDING_VALIDATOR
    def validate_import():
        binding_validator()
        require_idle_import_source(root,desktop_root)
    sync.BINDING_VALIDATOR=validate_import
    sync.HISTORY_ROOTS=[root]; sync.EXTERNAL_TARGETS={str(root):sorted(targets)}
    sync.DESKTOP_ROOTS=[desktop_root] if desktop_root else []
    return {**sync.sync_all(),'pending':pending}


def repair(profile_id):
    profile=next((p for p in store.load() if p['id']==profile_id),None)
    if profile is None: raise BackendError('profile_missing')
    return create(profile['name'],profile['kind'],repair_id=profile_id)


def create(name,kind,repair_id=None):
    name=name.strip()
    if not name or len(name)>60 or any(c in name for c in '/\\:\0\n'):raise BackendError('invalid_profile_name')
    if kind not in ('claude','magpie'):raise BackendError('invalid_request')
    source=SOURCE
    if not source.exists():raise BackendError('source_unavailable')
    private_dir(ROOT)
    with (ROOT/'registry.lock').open('a') as registry_lock, (ROOT/'sync.lock').open('a') as lock:
        fcntl.flock(registry_lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        profiles=store.load()
        if running(profiles): raise BackendError('profiles_running')
        recover_clone_repair()
        profiles=store.load(); apps=Path.home()/'Applications'; apps.mkdir(exist_ok=True)
        display=name if name.lower().startswith('claude') else 'Claude '+name
        target=apps/(display+'.app')
        previous=next((p for p in profiles if p['id']==repair_id),None) if repair_id else None
        if repair_id and previous is None: raise ValueError('Unknown profile')
        if previous:
            pid=previous['id']; bid=previous['bundleID']; target=Path(previous['bundle']); display=previous['name']; kind=previous['kind']
        else:
            if target.exists() or any(p['name']==display for p in profiles): raise BackendError('duplicate_profile')
            pid='p'+uuid.uuid4().hex[:12]; bid='local.anle.claude.desktop.'+pid
        base=ROOT/'profiles'/pid; stage=Path(tempfile.mkdtemp(prefix='clone-',dir=ROOT)); clone=stage/'Claude.app'
        try:
            subprocess.run(['/bin/cp','-cR',str(source),str(clone)],check=True,capture_output=True)
            info=clone/'Contents/Info.plist'; data=plistlib.loads(info.read_bytes())
            executable=data.get('CFBundleExecutable','Claude')
            binary=clone/'Contents/MacOS'/executable; binary.rename(binary.with_name('Claude.bin'))
            data.update(CFBundleExecutable='Claude',CFBundleName='Claude',CFBundleDisplayName=display,CFBundleIdentifier=bid)
            for key in ('CFBundleURLTypes','CFBundleDocumentTypes','UTImportedTypeDeclarations','UTExportedTypeDeclarations'):data.pop(key,None)
            info.write_bytes(plistlib.dumps(data))
            args=['/usr/bin/python3',str(ROOT/'desktop_launcher.py'),pid,str(target)]
            c='#include <unistd.h>\n#include <stdlib.h>\nint main(int argc,char **argv){char **a=calloc(argc+5,sizeof(char*));\n'
            c+=''.join('a[%d]=%s;\n'%(i,json.dumps(s,ensure_ascii=True)) for i,s in enumerate(args))
            c+='for(int i=1;i<argc;i++)a[i+3]=argv[i];execv(a[0],a);return 127;}\n'
            src=stage/'shim.c';src.write_text(c)
            subprocess.run(['/usr/bin/clang',str(src),'-o',str(clone/'Contents/MacOS/Claude')],check=True,capture_output=True)
            entitlements=Path(__file__).resolve().parent/'clone-entitlements.plist'
            if not entitlements.exists():raise ValueError('Thiếu entitlements của bộ nhân bản.')
            # Keep the original signed Electron frameworks, required for helper startup.
            for signed in (clone/'Contents/MacOS/Claude.bin',clone):
                subprocess.run(['/usr/bin/codesign','--force','--sign','-','--options','runtime','--entitlements',str(entitlements),str(signed)],check=True,capture_output=True)
            subprocess.run(['/usr/bin/codesign','--verify',str(clone)],check=True,capture_output=True)
            if not previous:
                private_dir(base/'code'); private_dir(base/'gui')
                config={'deploymentMode':'3p' if kind=='magpie' else '1p','preferences':{'sidebarMode':'epitaxy'}}
                (base/'gui'/'claude_desktop_config.json').write_text(json.dumps(config))
                if kind=='magpie':
                    g=base/'gui-3p';g.mkdir();(g/'claude_desktop_config.json').write_text(json.dumps(config))
                    library=g/'configLibrary';library.mkdir();cid=str(uuid.uuid4())
                    settings={'inferenceProvider':'gateway','inferenceGatewayBaseUrl':'http://127.0.0.1:3425','inferenceGatewayApiKey':'magpie-claude-desktop','inferenceGatewayAuthScheme':'bearer','disableDeploymentModeChooser':True,'deploymentDisplayName':display,'inferenceModels':['mythos-magpie-1026517788']}
                    (library/(cid+'.json')).write_text(json.dumps(settings));(library/(cid+'.json')).chmod(0o600)
                    (library/'_meta.json').write_text(json.dumps({'appliedId':cid,'entries':[{'id':cid,'name':display}]}))
            p={**(previous or {}), **dict(id=pid,name=display,kind=kind,bundle=str(target),bundleID=bid,
                   model=previous['model'] if previous else ('mythos-magpie-1026517788' if kind=='magpie' else 'sonnet'),
                   sourceVersion=data.get('CFBundleShortVersionString',''),shimDigest=digest((clone/'Contents/MacOS/Claude').read_bytes()))}
            if previous:
                backup=target.with_name(target.name+'.harbor-backup-'+uuid.uuid4().hex)
                journal={'state':'active','target':str(target),'backup':str(backup),'previous':previous}
                atomic_write(ROOT/'clone-repair.json',sync.json_bytes(journal))
                if target.exists(): os.rename(target,backup); fsync_dir(target.parent)
                os.rename(clone,target); fsync_dir(target.parent)
                store.save([p if item['id']==pid else item for item in profiles])
                journal['state']='committed'; atomic_write(ROOT/'clone-repair.json',sync.json_bytes(journal))
            else:
                os.rename(clone,target)
                try: store.save(profiles+[p])
                except Exception:
                    os.rename(target,clone); raise
            return p
        except subprocess.CalledProcessError as e:
            if previous: recover_clone_repair()
            elif base.exists():shutil.rmtree(base)
            raise ValueError('Không tạo được app: '+e.stderr.decode(errors='replace')[-1200:])
        except Exception:
            if previous: recover_clone_repair()
            elif base.exists():shutil.rmtree(base)
            raise
        finally:shutil.rmtree(stage)

def dispatch(arguments):
    command=arguments[0] if arguments else 'status'
    args=arguments[1:]
    arities={'status':0,'capabilities':0,'doctor':0,'verify':0,'check':0,'sync':0,
             'recover':0,'repair':1,'select':2,'create':2}
    if command!='import' and (command not in arities or len(args)!=arities[command]):
        raise BackendError('invalid_request')
    if command=='capabilities': return {'protocolVersion':VERSION,'features':list(FEATURES)}
    if command=='status': return status()
    if command=='import': return import_history(args)
    if command=='doctor': return doctor()
    if command=='repair': return repair(args[0])
    if command=='select':
        if args[1] not in ('true','false'): raise BackendError('invalid_request')
        return select_profile(args[0],args[1]=='true')
    if command=='create': return create(*args)
    if command=='recover':
        profiles,pending=configure()
        private_dir(ROOT)
        with (ROOT/'registry.lock').open('a') as registry_lock, (ROOT/'sync.lock').open('a') as lock:
            fcntl.flock(registry_lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
            fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
            if running(profiles): raise BackendError('profiles_running')
            recover_clone_repair()
            return {'recovered':sync.recover_transactions()}
    profiles,pending=configure()
    if command=='verify':
        from verify_coverage import verify
        if not sync.NAMES: raise BackendError('profiles_not_ready')
        private_dir(ROOT)
        with (ROOT/'sync.lock').open('a') as lock:
            fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
            if running(profiles): raise BackendError('profiles_running')
            result=verify(sync)
            atomic_write(ROOT/'last-verification.json', sync.json_bytes(result))
            if any(result[k] for k in ('incompleteGroups','missingTranscripts','conversationMismatches','auxiliaryMismatches','duplicateMembers','recordErrors')):
                raise BackendError('verification_failed', legacy_result=result)
            return result
    if len(sync.NAMES)<2: raise BackendError('profiles_not_ready')
    for p in profiles:
        if p['id'] in sync.NAMES and any(i['blocking'] for i in profile_health.inspect_profile(p)):
            raise BackendError('clone_stale')
    if command=='check':
        if recovery_issues(): raise BackendError('recovery_required')
        return {**sync.preflight(),'pending':pending,'eligible':list(sync.NAMES)}
    return {**sync.sync_all(),'pending':pending}


def main(arguments=None):
    import contextlib
    import io
    args=list(sys.argv[1:] if arguments is None else arguments)
    desktop=bool(args and args[0]=='--desktop-api')
    try:
        if desktop:
            if len(args)<2 or args[1]!=str(VERSION): raise BackendError('protocol_incompatible')
            args=args[2:]
        # argparse may emit raw argument values before raising SystemExit.
        with contextlib.redirect_stderr(io.StringIO()) if desktop else contextlib.nullcontext():
            result=dispatch(args)
        print(encode(envelope(result=result) if desktop else result))
        return 0
    except (Exception,SystemExit) as error:
        if isinstance(error,SystemExit): error=BackendError('invalid_request')
        if desktop: print(encode(envelope(error=error)))
        elif isinstance(error,BackendError) and error.legacy_result is not None:
            print(encode(error.legacy_result))
        else: print(str(error),file=sys.stderr)
        return 1


if __name__=='__main__': sys.exit(main())
