#!/usr/bin/env python3
"""Synchronize Code histories across registered Desktop clones, while closed."""
import types, re, datetime, fcntl, hashlib, json, os, shutil, subprocess, sys, time, uuid
from pathlib import Path
import history_inventory as inventory
import profile_store as store
from safe_io import atomic_write, stable_read, digest, contained, private_dir, parse_json, transcript_rows
import sync_transaction

HISTORY_ROOTS = None
DESKTOP_ROOTS = None
EXTERNAL_TARGETS = {}
BLOCKED = set()
DELETED_IDS = {}
DELETED_GROUPS = {}
RECORD_WARNINGS = []
BINDING_VALIDATOR = lambda: None
PREFLIGHT_NAMES = None

ROOT = store.ROOT
NAMES = {'pro1': 'Claude Pro 1', 'pro2': 'Claude Pro 2', 'magpie': 'Claude Magpie GPT-6.1'}
BOUND = ('remoteMcpServersConfig', 'sessionPermissionUpdates', 'alwaysAllowedReasons',
         'promptAppendSnapshot', 'toolSurfaceSnapshot', 'spawnSeed', 'cliBinaryPin',
         'enabledMcpTools', 'chromePermissionMode', 'autoChosenInApp',
         'autoModeServerFallbackPrompt')

def gui(profile):
    return ROOT / 'profiles' / profile / ('gui-3p' if profile == 'magpie' else 'gui')

def code(profile):
    return inventory.EXTERNAL.get(profile, ROOT / 'profiles' / profile / 'code')

def read(path):
    return parse_json(stable_read(path, ROOT)[0], path)

def processes():
    return subprocess.check_output(['/bin/ps', '-axo', 'command='], text=True).splitlines()

def running_profiles():
    lines = processes()
    return [p for p in NAMES if any(l.startswith(str(Path.home() / 'Applications' /
            (NAMES[p] + '.app') / 'Contents/MacOS/Claude.bin')) for l in lines)]

def validate_id(value):
    return str(uuid.UUID(value))

def account_dir(profile):
    return store.account(next(p for p in store.load() if p['id'] == profile))

def records():
    out = []; BLOCKED.clear(); DELETED_IDS.clear(); DELETED_GROUPS.clear(); RECORD_WARNINGS.clear()
    for profile in NAMES:
        root = account_dir(profile)
        DELETED_IDS[profile] = set(); DELETED_GROUPS[profile] = set()
        for path in root.parent.glob('*/local_*.json'):
            try:
                d = parse_json(stable_read(path, gui(profile))[0], path)
                if not isinstance(d, dict): raise ValueError('Record must be an object')
                if not d.get('cliSessionId'): raise ValueError('Unsupported record without local transcript')
                validate_id(d['cliSessionId'])
                if d.get('sessionId') != path.stem: raise ValueError('Session ID/path mismatch')
                prior = d.get('priorCliSessionIds', [])
                if not isinstance(prior, list): raise ValueError('Invalid prior chain')
                for sid in prior: validate_id(sid)
                if not isinstance(d.get('threeAppSync', {}), dict): raise ValueError('Invalid sync metadata')
                allowed = d.get('threeAppSync', {}).get('allowedTargets')
                if allowed is not None and (not isinstance(allowed, list) or
                        any(not isinstance(target, str) for target in allowed)):
                    raise ValueError('Invalid allowed target list')
                if (path.parent / ('deleted_' + path.stem.removeprefix('local_'))).exists():
                    DELETED_IDS[profile].update([d['cliSessionId'], *prior])
                    gid = d.get('threeAppSync', {}).get('group')
                    if gid: DELETED_GROUPS[profile].add(gid)
                    continue
                out.append((profile, path, d))
            except (OSError, ValueError, TypeError, AttributeError) as e:
                BLOCKED.add(profile)
                RECORD_WARNINGS.append({'record': str(path), 'profile': profile,
                                        'reason': 'invalid_managed_record', 'detail': str(e)})
    return [item for item in out if item[0] not in BLOCKED]

def transcript(profile, sid):
    validate_id(sid)
    return inventory.locate(code(profile), sid)

def snapshot(profile, path, record):
    main_id = record['cliSessionId']
    ids = list(dict.fromkeys([*record.get('priorCliSessionIds', []), main_id]))
    files, rows, signature, seen = {}, [], [], set()
    inputs = {}; input_roots = {}; auxiliary = {}; trees = {}
    if path.suffix == '.json' and path.exists():
        raw, _ = stable_read(path, gui(profile))
        if parse_json(raw, path) != record: raise ValueError('Record changed before snapshot: ' + str(path))
        inputs[str(path.absolute())] = digest(raw); input_roots[str(path.absolute())] = gui(profile)
    if profile in inventory.EXTERNAL and main_id in inventory.HISTORY_META_FILES:
        metadata_path, metadata_root, checksum = inventory.HISTORY_META_FILES[main_id]
        inputs[str(metadata_path.absolute())] = checksum; input_roots[str(metadata_path.absolute())] = metadata_root
    def capture(file):
        data, modified = stable_read(file, code(profile))
        inputs[str(file.absolute())] = digest(data); input_roots[str(file.absolute())] = code(profile)
        return data, modified
    for sid in ids:
        t = transcript(profile, sid)
        data, _ = capture(t)
        body = list(transcript_rows(data, t))
        if any(not isinstance(r, dict) or not isinstance(r.get('message', {}), dict) for r in body):
            raise ValueError('Invalid transcript row')
        files[sid] = (t, body)
        auxiliary[sid] = {}
        for category, folder in [('file-history', code(profile)/'file-history'/sid),
                                 ('tasks', code(profile)/'tasks'/sid), ('session', t.with_suffix(''))]:
            contained(folder, code(profile))
            trees[str(folder.absolute())] = tree_files(folder, code(profile))
            if not folder.exists(): continue
            for f in sorted(folder.rglob('*')):
                contained(f, code(profile))
                if f.is_file():
                    payload, modified = capture(f)
                    auxiliary[sid][category + '/' + str(f.relative_to(folder))] = (f, payload, modified)

        if sid == main_id:
            rows = body
        for row in body:
            if row.get('type') not in ('user', 'assistant') or row.get('isSidechain'):
                continue
            key = row.get('uuid')
            if key and key in seen:
                continue
            seen.add(key)
            msg = row.get('message', {})
            stable = {'type': row['type'], 'uuid': key,
                      'role': msg.get('role'), 'content': msg.get('content'),
                      'stop_reason': msg.get('stop_reason')}
            signature.append(hashlib.sha256(json.dumps(stable, sort_keys=True, ensure_ascii=False).encode()).hexdigest())
    # An idle child process is normal. Use the saved completed-turn marker instead.
    frames = [r for r in rows if r.get('type') in ('user', 'assistant') and not r.get('isSidechain')]
    busy = False
    if frames:
        last_user = max((i for i, r in enumerate(frames) if r['type'] == 'user' and
                         r.get('message', {}).get('role') == 'user'), default=-1)
        marker = record.get('lastAssistantUuid')
        final = max((i for i, r in enumerate(frames) if r['type'] == 'assistant' and
                     r.get('uuid') == marker), default=-1)
        busy = last_user >= 0 and (final <= last_user or
               not any(r.get('subtype') == 'stop_hook_summary' and
                       r.get('timestamp', '') >= frames[final].get('timestamp', '')
                       for r in rows))
    text = '\n'.join(json.dumps(r, ensure_ascii=False) for _, body in files.values() for r in body)
    references = {}
    for category in ('plans', 'paste-cache'):
        folder = code(profile)/category
        contained(folder, code(profile))
        trees[str(folder.absolute())] = tree_files(folder, code(profile))
        for f in folder.glob('*'):
            if f.name in text:
                contained(f, code(profile))
                if f.is_file(): references[category+'/'+f.name] = capture(f)[0]
    return {'profile': profile, 'path': path, 'record': record, 'files': files,
            'signature': signature, 'busy': busy, 'inputs': inputs, 'auxiliary': auxiliary,
            'references': references, 'input_roots': input_roots, 'trees': trees}


def tree_files(folder, root):
    contained(folder, root)
    paths=set()
    for path in folder.rglob('*'):
        contained(path, root)
        if path.is_file(): paths.add(str(path.absolute()))
    return paths

def validate_snapshot(source, tx):
    for folder, original in source.get('trees', {}).items():
        current = tree_files(Path(folder), code(source['profile']))
        if original-current or (current-original)-set(tx.expected):
            raise ValueError('Source file set changed after snapshot: ' + folder)
    for name, expected in source.get('inputs', {}).items():
        data, _ = stable_read(Path(name), source.get('input_roots', {}).get(name, code(source['profile'])))
        if digest(data) != tx.expected.get(str(Path(name).absolute()), expected):
            raise ValueError('Source changed after snapshot: ' + name)


def live_cli_ids():
    result = {}
    for line in processes():
        for profile in NAMES:
            if str(gui(profile)/'claude-code') in line and '/Contents/MacOS/claude' in line:
                result.setdefault(profile,set()).update(re.findall(r'[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}',line))
    return result

def preflight():
    global NAMES
    selected = NAMES
    if PREFLIGHT_NAMES is not None: NAMES = PREFLIGHT_NAMES
    try: return _preflight()
    finally: NAMES = selected

def _preflight():
    busy, errors = [], []
    active = running_profiles(); live = live_cli_ids()
    for p,path,d in records():
        # Historical interrupted sessions are not running turns. Only inspect live SDKs.
        if p not in live:continue
        if d['cliSessionId'] not in live[p] and d.get('latestUserFrameAt',0) < (time.time()-300)*1000:continue
        try:
            s = snapshot(p,path,d)
            if s['busy'] and p in active:busy.append(NAMES[p]+': '+d.get('title',path.stem))
        except (OSError,ValueError):
            busy.append(NAMES[p]+': đang ghi phiên, chờ lưu xong')
    for p in BLOCKED & set(active) & set(live):
        busy.append(NAMES[p]+': cannot inspect active session safely')
    return {'busy':busy,'errors':errors,'running':active}

def prefix(left, right):
    return len(left) <= len(right) and left == right[:len(left)]

class Transaction(sync_transaction.Transaction):
    def __init__(self): super().__init__(ROOT)


def recover_transactions(): return sync_transaction.recover(ROOT)

def json_bytes(d):
    return (json.dumps(d, ensure_ascii=False, indent=2, sort_keys=True) + '\n').encode()

def copy_session(source, profile, existing, group_id, tx):
    validate_snapshot(source, tx)
    for name, checksum in source.get('inputs', {}).items(): tx.guards.setdefault(name, checksum)
    record = source['record']
    old = record['cliSessionId']
    if existing:
        dest_record = dict(existing['record'])
        new = dest_record['cliSessionId']
        local = dest_record['sessionId']
        record_path = existing['path']
        dest_file = existing['files'][new][0]
    else:
        new = str(uuid.uuid4()); local = 'local_' + str(uuid.uuid4())
        record_path = account_dir(profile) / (local + '.json')
        rel = source['files'][old][0].parent.relative_to(code(source['profile']))
        dest_file = code(profile) / rel / (new + '.jsonl')
        allowed = ('title', 'titleSource', 'cwd', 'originCwd', 'createdAt', 'isArchived', 'archived')
        dest_record = {k: record[k] for k in allowed if k in record}
        dest_record.update(model=globals().get('PROFILE_MODELS', {}).get(profile, 'mythos-magpie-1026517788' if profile == 'magpie' else 'sonnet'),
                           permissionMode='default')
    id_map = {old: new}; prior_ids = []; prior_map = {}
    origins = {v: k for k, v in record.get('threeAppSync', {}).get('priorMap', {}).items()}
    target_map = dest_record.get('threeAppSync', {}).get('priorMap', {})
    for sid in record.get('priorCliSessionIds', []):
        if sid == old: continue
        origin = origins.get(sid, sid)
        mapped = sid if existing and existing['profile'] == source['profile'] else target_map.get(origin, str(uuid.uuid4()))
        validate_id(mapped)
        id_map[sid] = mapped; prior_ids.append(mapped); prior_map[origin] = mapped
    for sid, (src, rows) in source['files'].items():
        mapped = id_map[sid]
        target = dest_file if sid == old else (existing['files'][mapped][0] if existing and mapped in existing['files'] else code(profile) / src.parent.relative_to(code(source['profile'])) / (mapped + '.jsonl'))
        converted = []
        for row in rows:
            row = dict(row)
            if row.get('sessionId') in id_map: row['sessionId'] = id_map[row['sessionId']]
            converted.append(json.dumps(row, ensure_ascii=False))
        same_chain = existing and source['signature'] == existing['signature'] and mapped in existing['files']
        if not same_chain:
            tx.write(target, ('\n'.join(converted) + '\n').encode())
        for key, (_, payload, _) in source.get('auxiliary', {}).get(sid, {}).items():
            category, relative = key.split('/', 1)
            folder = target.with_suffix('') if category == 'session' else code(profile)/category/mapped
            tx.write(folder/relative, payload)
    for key, payload in source.get('references', {}).items():
        target = code(profile)/key
        if target.exists() and stable_read(target, code(profile))[0] != payload:
            inventory.WARNINGS.append({'record': str(target), 'reason': 'reference_conflict_preserved'})
            continue
        tx.write(target, payload)
    # Keep target account permissions/model, update session history and visible status.
    for key in ('title', 'titleSource', 'lastActivityAt', 'completedTurns', 'latestUserFrameAt',
                'lastAssistantUuid', 'postTurnSummary', 'postTurnSummaryFor'):
        if key in record:
            dest_record[key] = record[key]
    dest_record.update(sessionId=local, cliSessionId=new, priorCliSessionIds=prior_ids,
                       threeAppSync={'group': group_id, 'priorMap': prior_map})
    if source.get('allowedTargets') is not None:
        dest_record['threeAppSync']['allowedTargets'] = sorted(source['allowedTargets'])
    tx.write(record_path, json_bytes(dest_record))
    return str(record_path)

def merge_auxiliary(canonical, members, baseline):
    """Reconcile file changes independently; conflicting edits remain local and visible."""
    result = dict(canonical); result['auxiliary'] = {}; next_state = dict(baseline)
    canonical_ids = list(canonical['files'])
    equal = [m for m in members if prefix(m['signature'], canonical['signature']) and len(m['files']) == len(canonical_ids)]
    for index, sid in enumerate(canonical_ids):
        variants = {}
        for m in equal:
            other_sid = list(m['files'])[index]
            for key, item in m['auxiliary'][other_sid].items():
                variants.setdefault(key, {})[digest(item[1])] = item
        result['auxiliary'][sid] = {}
        for key, versions in variants.items():
            identity = str(index) + '/' + key
            changed = {h: v for h, v in versions.items() if h != baseline.get(identity)}
            if len(versions) == 1:
                chosen = next(iter(versions))
            elif len(changed) == 1 and identity in baseline:
                chosen = next(iter(changed))
            else:
                inventory.WARNINGS.append({'session': canonical['record']['cliSessionId'],
                                           'file': key, 'reason': 'auxiliary_conflict_preserved'})
                continue
            result['auxiliary'][sid][key] = versions[chosen]; next_state[identity] = chosen
    return result, next_state

def sync_all():
    ROOT.mkdir(parents=True, exist_ok=True)
    with (ROOT / 'sync.lock').open('w') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            for attempt in range(10):
                time.sleep(0.1)
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB); break
                except BlockingIOError:
                    if attempt==9: raise ValueError('App hoặc một lượt đồng bộ khác đang giữ dữ liệu.')
        if running_profiles():
            raise ValueError('App vẫn đang mở. Dùng nút Đồng bộ tất cả để tự đóng và mở lại app.')
        recover_transactions()
        check = preflight()
        if check['busy'] or check['errors']:
            raise ValueError('Chưa đồng bộ: ' + '; '.join(check['busy'] + check['errors']))
        BINDING_VALIDATOR()
        manifest_path = ROOT / 'sync-state.json'
        state = read(manifest_path) if manifest_path.exists() else {'version': 1, 'members': {}}
        if not isinstance(state, dict) or state.get('version') != 1 or not isinstance(state.get('members'), dict):
            raise ValueError('Unsupported sync-state schema')
        context = types.SimpleNamespace(ROOT=ROOT,NAMES=NAMES,PROFILE_MODELS=globals().get("PROFILE_MODELS",{}),code=code,account_dir=account_dir,json_bytes=json_bytes,HISTORY_ROOTS=HISTORY_ROOTS,DESKTOP_ROOTS=DESKTOP_ROOTS,EXTERNAL_TARGETS=EXTERNAL_TARGETS,BLOCKED=BLOCKED,DELETED_IDS=DELETED_IDS)
        inventory.initialize(context)
        managed = records()
        inventory.WARNINGS.extend(RECORD_WARNINGS)
        # A tombstone can outlive its JSON record; lineage still remembers its group.
        for profile in NAMES:
            for tombstone in account_dir(profile).parent.glob('*/deleted_*'):
                former = tombstone.parent/('local_' + tombstone.name.removeprefix('deleted_') + '.json')
                gid = state['members'].get(str(former))
                if gid: DELETED_GROUPS[profile].add(gid)
                if not former.exists():
                    # Without the record its SID cannot safely be inferred: no orphan discovery here.
                    BLOCKED.add(profile)
                    inventory.WARNINGS.append({'profile':profile, 'reason':'tombstone_without_record'})

        groups = {}
        for p, path, record in managed:
            gid = state['members'].get(str(path)) or record.get('threeAppSync', {}).get('group') or str(uuid.uuid4())
            groups.setdefault(gid, []).append({'profile':p,'path':path,'record':record})
        discovered, source_ids = inventory.candidates(context, managed, state)
        for p,path,record,signature,gid in discovered:
            groups.setdefault(gid, []).append({'profile':p,'path':path,'record':record,'signature':signature})
        next_auxiliary = dict(state.get('auxiliary', {}))
        restrictions = dict(state.get('targets', {}))
        for gid, descriptors in groups.items():
            for item in descriptors:
                allowed = item['record'].get('threeAppSync', {}).get('allowedTargets')
                if allowed is not None:
                    restrictions[gid] = sorted(set(restrictions.get(gid, allowed)) & set(allowed))
        tx = Transaction(); next_members = {path:gid for path,gid in state['members'].items() if not any(Path(path).is_relative_to(gui(p)) for p in NAMES if p not in BLOCKED)}; branches = 0; count = 0
        try:
            captured = []
            for gid, descriptors in groups.items():
                members = []; failed_profiles = set()
                for descriptor in descriptors:
                    try:
                        p=descriptor['profile']; d=descriptor['record']; sid=d['cliSessionId']
                        member=snapshot(p,descriptor['path'],d)
                        members.append(member); captured.append(member)
                        for name, checksum in member['inputs'].items(): tx.guards.setdefault(name, checksum)
                    except (OSError,ValueError,TypeError,KeyError,AttributeError) as e:
                        failed_profiles.add(descriptor['profile'])
                        if str(descriptor['path']) in state['members']:
                            next_members[str(descriptor['path'])] = state['members'][str(descriptor['path'])]
                        inventory.WARNINGS.append({'record':str(descriptor['path']),'reason':'cannot_load_history','detail':str(e)})
                if not members:continue
                maxima = []
                # Equal conversations can have different valid chain layouts.  Prefer the
                # fullest layout so a shortened main transcript never replaces history.
                for member in sorted(members, key=lambda x: (len(x['signature']), len(x['files'])), reverse=True):
                    if not any(prefix(member['signature'], x['signature']) for x in maxima):
                        maxima.append(member)
                claimed = set()
                for index, canonical in enumerate(maxima):
                    branch_id = gid if index == 0 else str(uuid.uuid4())
                    if index:
                        branches += 1
                    selected={}
                    authorized = set(restrictions.get(gid, NAMES))
                    for member in members:
                        if member['profile'] in inventory.EXTERNAL:
                            authorized &= inventory.EXTERNAL_TARGETS[member['profile']]
                    if any(m['profile'] in inventory.EXTERNAL for m in members) or gid in restrictions:
                        restrictions[branch_id] = sorted(authorized)
                    targets = authorized & (set(NAMES) - BLOCKED - failed_profiles)
                    for profile in sorted(targets):
                        if gid in DELETED_GROUPS.get(profile, set()): continue
                        choices=[m for m in members if m['profile']==profile and str(m['path']) not in claimed and prefix(m['signature'],canonical['signature'])]
                        selected[profile]=max(choices,key=lambda x:len(x['signature']),default=None)
                    canonical, aux_state = merge_auxiliary(canonical, members, state.get('auxiliary', {}).get(gid, {}))
                    if branch_id in restrictions: canonical['allowedTargets'] = restrictions[branch_id]
                    next_auxiliary[branch_id] = aux_state
                    for profile,existing in selected.items():
                        if existing:claimed.add(str(existing['path']))
                        path=copy_session(canonical,profile,existing,branch_id,tx)
                        next_members[path]=branch_id
                    count += 1
            for source in captured: validate_snapshot(source, tx)
            BINDING_VALIDATOR()
            inventory.persist(context, tx)
            tx.write(manifest_path, json_bytes({'version': 1, 'members': next_members, 'auxiliary': next_auxiliary, 'targets': restrictions}))
            tx.report()
            report = {'profiles': len(NAMES), 'sessions': count, 'newBranches': branches,
                      'filesChanged':sum(p.name not in ('history-index.json','history-audit.json','sync-state.json') for p,_ in tx.changes), 'backup': str(tx.root),
                      'sourceHistories':len(source_ids), 'warnings':len(inventory.WARNINGS),
                      'audit':str(ROOT/'history-audit.json')}
            tx.write(ROOT / 'last-sync.json', json_bytes(report))
            tx.commit()
            return report
        except Exception as original:
            if tx.state == 'committed': raise
            try: tx.rollback()
            except Exception as recovery:
                raise RuntimeError(str(original) + '; recovery required: ' + str(recovery)) from original
            raise

if __name__ == '__main__':
    os.execv(sys.executable,[sys.executable,str(Path(__file__).with_name('manager.py')),*sys.argv[1:]])
