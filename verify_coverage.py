"""Fresh read-only verification; never trusts history-index or summary caches."""
import argparse
import hashlib
import json
from pathlib import Path
from safe_io import stable_read, digest, parse_json, transcript_rows


def verify(sync):
    state_path=sync.ROOT/'sync-state.json'
    state=parse_json(stable_read(state_path,sync.ROOT)[0], state_path) if state_path.exists() else {'members':{}}
    managed=sync.records()
    groups={}; missing=[]; auxiliary=[]; duplicates=[]
    # Locate afresh as well: an old in-memory path index must not hide added copies.
    sync.inventory.TRANSCRIPTS.clear()
    for profile,path,record in managed:
        gid=state['members'].get(str(path)) or record.get('threeAppSync',{}).get('group')
        if not gid: missing.append(str(path)+': no group'); continue
        signature=[]; seen=set(); ids=list(dict.fromkeys([*record.get('priorCliSessionIds',[]),record['cliSessionId']]))
        try:
            for index,sid in enumerate(ids):
                sync.validate_id(sid)
                candidates=list((sync.code(profile)/'projects').glob('*/'+sid+'.jsonl'))
                if not candidates: raise ValueError('Missing transcript '+sid)
                bodies=[stable_read(p,sync.code(profile))[0] for p in candidates]
                if len({digest(b) for b in bodies})!=1: raise ValueError('Ambiguous transcript '+sid)
                for row in transcript_rows(bodies[0], candidates[0]):
                    if row.get('type') not in ('user','assistant') or row.get('isSidechain'): continue
                    mid=row.get('uuid')
                    if mid and mid in seen: continue
                    seen.add(mid); msg=row.get('message',{})
                    stable={'type':row['type'],'uuid':mid,'role':msg.get('role'),'content':msg.get('content'),'stop_reason':msg.get('stop_reason')}
                    signature.append(hashlib.sha256(json.dumps(stable,sort_keys=True,ensure_ascii=False).encode()).hexdigest())
                for key,expected in state.get('auxiliary',{}).get(gid,{}).items():
                    chain,category,relative=key.split('/',2)
                    if int(chain)!=index: continue
                    base=candidates[0].with_suffix('') if category=='session' else sync.code(profile)/category/sid
                    target=base/relative
                    if not target.exists() or digest(stable_read(target,sync.code(profile))[0])!=expected:
                        auxiliary.append(str(target))
            members=groups.setdefault(gid,{})
            if profile in members: duplicates.append(str(path))
            members[profile]=signature
        except (OSError,ValueError,TypeError,AttributeError) as e: missing.append(str(path)+': '+str(e))
    expected_groups=set()
    for name,gid in state.get('members',{}).items():
        path=Path(name)
        profile=next((p for p in sync.NAMES if path.is_relative_to(sync.gui(p))),None)
        if profile is None: continue
        tombstone=path.parent/('deleted_'+path.stem.removeprefix('local_'))
        if tombstone.exists(): continue
        expected_groups.add(gid)
        if not path.exists(): missing.append(str(path)+': missing Desktop record')
    incomplete=list(expected_groups-set(groups)); mismatches=[]
    for gid,members in groups.items():
        targets=set(state.get('targets',{}).get(gid,sync.NAMES)) & set(sync.NAMES)
        targets -= {p for p in sync.NAMES if gid in sync.DELETED_GROUPS.get(p,set())}
        if set(members)!=targets: incomplete.append(gid)
        if any(s!=next(iter(members.values())) for s in members.values()): mismatches.append(gid)
    return {'profiles':len(sync.NAMES),'sessionGroups':len(groups),'incompleteGroups':len(incomplete),
            'missingTranscripts':missing,'conversationMismatches':mismatches,
            'auxiliaryMismatches':auxiliary,'duplicateMembers':duplicates,'recordErrors':list(sync.RECORD_WARNINGS)}


def main():
    parser=argparse.ArgumentParser(); parser.add_argument('--fresh',action='store_true',help='Always enabled; retained for explicit usage')
    parser.parse_args()
    import fcntl
    import manager
    manager.configure()
    with (manager.ROOT/'sync.lock').open('a') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        if manager.sync.running_profiles(): raise ValueError('Close profiles before fresh verification')
        result=verify(manager.sync)
    print(json.dumps(result,ensure_ascii=False,indent=2))
    if any(result[k] for k in ('incompleteGroups','missingTranscripts','conversationMismatches','auxiliaryMismatches','duplicateMembers','recordErrors')):
        raise SystemExit(1)

if __name__=='__main__': main()
