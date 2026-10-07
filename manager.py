#!/usr/bin/env python3
"""Native manager backend. stdout carries small JSON results only."""
import fcntl, json, os, plistlib, shutil, subprocess, sys, tempfile, uuid
from pathlib import Path
import profile_store as store
import desktop_sync as sync
import profile_health
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
        if p is None: raise ValueError('Unknown profile')
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
        result.append({**{k:v for k,v in p.items() if k!='legacyAccount'},'syncEnabled':p.get('syncEnabled',False),'ready':ready,'running':p['id'] in running,'sessions':count,'archived':archived})
    last=None
    try:
        if (ROOT/'last-sync.json').exists():
            last=json.loads((ROOT/'last-sync.json').read_text())
            if not isinstance(last, dict) or any(not isinstance(last.get(k), int) for k in ('profiles','sessions','newBranches','filesChanged')) or not isinstance(last.get('backup'),str):
                raise ValueError('Invalid sync report')
    except (OSError,ValueError):
        last=None; pending.append('Báo cáo cũ bị lỗi; profile vẫn có thể sử dụng.')
    return {'profiles':result,'pending':pending,'lastSync':last}

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
    issues=[]
    for p in store.load(): issues.extend(profile_health.inspect_profile(p,verify_signature=True))
    journal=ROOT/'clone-repair.json'
    if journal.exists() and json.loads(journal.read_text()).get('state')=='active':
        issues.append({'code':'interrupted_clone_repair','blocking':True,'detail':'Run repair again while all profiles are closed.'})
    for path in (ROOT/'sync-backups').glob('*/journal.json'):
        if json.loads(path.read_text()).get('state')=='active':
            issues.append({'code':'pending_recovery','blocking':True,'detail':'Run recover with all profiles closed: '+str(path.parent)})
    return {'issues':issues,'ok':not any(i['blocking'] for i in issues)}


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
    sync.HISTORY_ROOTS=[root]; sync.EXTERNAL_TARGETS={str(root):sorted(targets)}
    sync.DESKTOP_ROOTS=[Path(args.desktop_root).expanduser().resolve()] if args.desktop_root else []
    return {**sync.sync_all(),'pending':pending}


def repair(profile_id):
    profile=next((p for p in store.load() if p['id']==profile_id),None)
    if profile is None: raise ValueError('Unknown profile')
    return create(profile['name'],profile['kind'],repair_id=profile_id)


def create(name,kind,repair_id=None):
    name=name.strip()
    if not name or len(name)>60 or any(c in name for c in '/\\:\0\n'):raise ValueError('Tên cần 1–60 ký tự, không chứa /, \\, : hoặc xuống dòng.')
    if kind not in ('claude','magpie'):raise ValueError('Loại profile không hợp lệ')
    source=SOURCE
    if not source.exists():raise ValueError('Cần cài Claude chính thức tại /Applications/Claude.app.')
    private_dir(ROOT)
    with (ROOT/'registry.lock').open('a') as registry_lock, (ROOT/'sync.lock').open('a') as lock:
        fcntl.flock(registry_lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        profiles=store.load()
        if running(profiles): raise ValueError('Đóng tất cả profile trước khi tạo/sửa clone.')
        recover_clone_repair()
        profiles=store.load(); apps=Path.home()/'Applications'; apps.mkdir(exist_ok=True)
        display=name if name.lower().startswith('claude') else 'Claude '+name
        target=apps/(display+'.app')
        previous=next((p for p in profiles if p['id']==repair_id),None) if repair_id else None
        if repair_id and previous is None: raise ValueError('Unknown profile')
        if previous:
            pid=previous['id']; bid=previous['bundleID']; target=Path(previous['bundle']); display=previous['name']; kind=previous['kind']
        else:
            if target.exists() or any(p['name']==display for p in profiles): raise ValueError('Tên này đã được sử dụng. Chọn tên khác.')
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

if __name__=='__main__':
    try:
        command=sys.argv[1] if len(sys.argv)>1 else 'status'
        if command=='status':result=status()
        elif command=='import': result=import_history(sys.argv[2:])
        elif command=='verify':
            from verify_coverage import verify
            profiles,pending=configure()
            if not sync.NAMES: raise ValueError('Select initialized profiles before verification')
            with (ROOT/'sync.lock').open('a') as lock:
                fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
                if running(profiles): raise ValueError('Close profiles before verification')
                result=verify(sync)
                if any(result[k] for k in ('incompleteGroups','missingTranscripts','conversationMismatches','auxiliaryMismatches','duplicateMembers','recordErrors')):
                    print(json.dumps(result,ensure_ascii=False)); sys.exit(1)
        elif command=='doctor': result=doctor()
        elif command=='repair': result=repair(sys.argv[2])
        elif command=='recover':
            profiles,pending=configure()
            with (ROOT/'registry.lock').open('a') as registry_lock, (ROOT/'sync.lock').open('a') as lock:
                fcntl.flock(registry_lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
                fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
                if running(profiles): raise ValueError('Close all profiles before recovery')
                recover_clone_repair()
                result={'recovered':sync.recover_transactions()}
        elif command=='select': result=select_profile(sys.argv[2], sys.argv[3]=='true')
        elif command=='create': result=create(sys.argv[2],sys.argv[3])
        elif command in ('check','sync'):
            profiles,pending=configure()
            if len(sync.NAMES)<2:raise ValueError('Cần ít nhất hai profile đã đăng nhập và mở tab Code.')
            if command=='check':result={**sync.preflight(),'pending':pending,'eligible':list(sync.NAMES)}
            else:result={**sync.sync_all(),'pending':pending}
        else:raise ValueError('Lệnh không hợp lệ')
        print(json.dumps(result,ensure_ascii=False))
    except BlockingIOError: print('Đóng các profile đang chạy hoặc chờ thao tác hiện tại hoàn tất.',file=sys.stderr);sys.exit(1)
    except Exception as e:print(str(e),file=sys.stderr);sys.exit(1)
