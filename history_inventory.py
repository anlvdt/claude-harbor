"""Discover local Claude Code histories, including those with no Desktop record."""
import datetime, hashlib, json, uuid, re
from pathlib import Path
from safe_io import stable_read, digest, contained, parse_json, transcript_rows

EXTERNAL = {}
TRANSCRIPTS = {}
SUMMARIES = {}
PATH_CACHE = {}
WARNINGS = []
SOURCE_STATS = {}
HISTORY_META = {}
PROJECT_PATHS = {}
HISTORY_META_FILES = {}
EXTERNAL_BLOCKED = False
BASE_ROOT = None
EXTERNAL_TARGETS = {}
EXCLUDED = set()

def initialize(module):
    global BASE_ROOT, PATH_CACHE, EXTERNAL_BLOCKED
    EXTERNAL_TARGETS.clear(); EXCLUDED.clear(); EXTERNAL.clear(); TRANSCRIPTS.clear(); SUMMARIES.clear(); WARNINGS.clear(); SOURCE_STATS.clear(); HISTORY_META.clear()
    BASE_ROOT = module.ROOT
    HISTORY_META_FILES.clear(); EXTERNAL_BLOCKED = False
    PROJECT_PATHS.clear()
    configs=[module.code(p)/'.claude.json' for p in module.NAMES]
    for config in configs:
        try:
            for cwd in json.loads(config.read_text()).get('projects',{}):
                slug=re.sub(r'[^a-zA-Z0-9]','-',cwd)
                PROJECT_PATHS.setdefault(slug,set()).add(cwd)
        except (OSError,ValueError,AttributeError,TypeError):pass
    PATH_CACHE = {}  # persisted diagnostics are never trusted as content evidence
    candidates = module.HISTORY_ROOTS or []
    bindings = getattr(module, 'EXTERNAL_TARGETS', {})
    for i, root in enumerate(candidates):
        root = Path(root)
        targets = set(bindings.get(str(root), [])) & set(module.NAMES)
        if not targets:
            WARNINGS.append({'source': str(root), 'reason': 'external_source_not_authorized'})
            continue
        if (root/'projects').is_dir():
            key = 'history-' + str(i)
            EXTERNAL[key] = root; EXTERNAL_TARGETS[key] = targets
    for root in [*EXTERNAL.values(), *(module.code(p) for p in module.NAMES)]:
        index(root)
    # Desktop gives better titles, workspace and archive information than bare CLI files.
    desktop_roots = module.DESKTOP_ROOTS or []
    for gui in desktop_roots:
        record_count = 0; missing = 0
        for path in gui.glob('claude-code-sessions/*/*/local_*.json'):
            try:
                raw, _ = stable_read(path, gui)
                record = parse_json(raw, path); sid = record.get('cliSessionId')
                if (path.parent/('deleted_' + path.stem.removeprefix('local_'))).exists():
                    EXCLUDED.update([sid, *record.get('priorCliSessionIds', [])]); continue
                if not sid: raise ValueError('Unsupported Desktop record')
                uuid.UUID(sid)
                prior=record.get('priorCliSessionIds',[])
                if not isinstance(prior,list): raise ValueError('Invalid prior chain')
                for previous in prior: uuid.UUID(previous)
                if sid in HISTORY_META and HISTORY_META[sid] != record: raise ValueError('Ambiguous Desktop ownership')
                record_count += 1
                HISTORY_META[sid] = record
                HISTORY_META_FILES[sid] = (path, gui, digest(raw))
                if not any(sid in files for files in TRANSCRIPTS.values()):
                    missing += 1
                    WARNINGS.append({'record':str(path),'session':sid,'reason':'desktop_record_without_transcript'})
            except (OSError, ValueError, TypeError, AttributeError) as e:
                EXTERNAL_BLOCKED = True
                WARNINGS.append({'record':str(path),'reason':'invalid_desktop_record','detail':str(e)})
        SOURCE_STATS[str(gui)] = {'desktopRecords':record_count,'missingTranscripts':missing}


def index(root):
    key = str(root)
    if key not in TRANSCRIPTS:
        files = {}
        for path in (root/'projects').glob('*/*.jsonl'):
            try: sid = str(uuid.UUID(path.stem))
            except ValueError:continue
            files.setdefault(sid, []).append(path)
        TRANSCRIPTS[key] = files
        SOURCE_STATS[key] = {'transcripts':sum(len(p) for p in files.values()),'uniqueSessionIds':len(files)}
    return TRANSCRIPTS[key]


def locate(root, sid):
    candidates = index(root).get(sid, [])
    if not candidates:
        candidates = list((root/'projects').glob('*/'+sid+'.jsonl'))
        if candidates:index(root)[sid] = candidates
    if not candidates:raise ValueError('Missing transcript '+sid)
    contents = {digest(stable_read(p, root)[0]) for p in candidates}
    if len(contents) != 1: raise ValueError('Ambiguous transcript ' + sid)
    return sorted(candidates)[0]


def timestamp(value, fallback):
    try:return int(datetime.datetime.fromisoformat(value.replace('Z','+00:00')).timestamp()*1000)
    except (ValueError, AttributeError):return fallback


def summarize(path):
    data, modified = stable_read(path, path.parent.parent.parent)
    stamp = [len(data), modified]
    fingerprint = (str(path.absolute()), digest(data))
    if fingerprint in SUMMARIES:
        summary = SUMMARIES[fingerprint]
    else:
        first_time = int(modified/1_000_000); last_time = first_time
        cwd = ''; title = ''; prompt = ''; signature = []; last_assistant = None
        seen = set(); turns = 0; plan_names = set()
        for r in transcript_rows(data, path):
            cwd = r.get('cwd') or cwd
            if r.get('timestamp'):
                t = timestamp(r['timestamp'],first_time)
                if not signature:first_time=t
                last_time=t
            if r.get('type') in ('custom-title','ai-title'):
                title = r.get('customTitle') or r.get('aiTitle') or r.get('title') or title
            if r.get('slug'):plan_names.add(r['slug']+'.md')
            if r.get('type') not in ('user','assistant') or r.get('isSidechain'):continue
            msg = r.get('message',{}); mid = r.get('uuid')
            if not isinstance(msg, dict): raise ValueError('Invalid message')
            if mid and mid in seen:continue
            seen.add(mid)
            stable={'type':r['type'],'uuid':mid,'role':msg.get('role'),'content':msg.get('content'),'stop_reason':msg.get('stop_reason')}
            signature.append(hashlib.sha256(json.dumps(stable,sort_keys=True,ensure_ascii=False).encode()).hexdigest())
            if r['type']=='user':
                turns += 1
                if not prompt:
                    content=msg.get('content','')
                    if isinstance(content,str):prompt=content
                    elif isinstance(content,list):prompt=' '.join(b.get('text','') for b in content if isinstance(b,dict) and b.get('type')=='text')
            else:last_assistant=mid
        cwd = cwd or HISTORY_META.get(path.stem,{}).get('cwd','')
        known=PROJECT_PATHS.get(path.parent.name,set())
        if not cwd and len(known)==1:cwd=next(iter(known))
        if not cwd:
            # Keep unresolved histories in the report, never guess a filesystem path.
            raise ValueError('Transcript has no working directory: '+str(path))
        title=title or prompt.strip().split('\n')[0][:120] or path.stem
        summary={'cwd':cwd,'title':title,'createdAt':first_time,'lastActivityAt':last_time,'signature':signature,
                 'lastAssistantUuid':last_assistant,'completedTurns':turns,'planNames':sorted(plan_names)}
        SUMMARIES[fingerprint]=summary
    PATH_CACHE[str(path)]={'stamp':stamp,'summary':summary}
    return summary


def candidates(module, managed, state):
    linked = {}
    for p,path,d in managed:
        gid=state['members'].get(str(path)) or d.get('threeAppSync',{}).get('group')
        if gid:
            for sid in [d['cliSessionId'],*d.get('priorCliSessionIds',[])]:linked[sid]=gid
    out=[]; scanned = set()
    for profile in [*module.NAMES,*EXTERNAL]:
        root=module.code(profile)
        if profile in EXTERNAL and EXTERNAL_BLOCKED: continue
        if profile in getattr(module, 'BLOCKED', set()): continue
        owned={sid for p,_,d in managed if p==profile for sid in [d['cliSessionId'], *d.get('priorCliSessionIds', [])]}
        owned.update(getattr(module, 'DELETED_IDS', {}).get(profile, set())); owned.update(EXCLUDED)
        if profile in EXTERNAL:
            owned.update(previous for sid, meta in HISTORY_META.items() if sid in index(root) for previous in meta.get('priorCliSessionIds', []))
        for sid, files in index(root).items():
            if sid in owned:continue
            try:
                path=locate(root, sid)
                summary=summarize(path)
                if not summary['signature']:
                    WARNINGS.append({'transcript':str(path),'reason':'no_conversation_messages'});continue
            except (OSError,ValueError) as e:
                WARNINGS.append({'transcript':str(files[0]),'reason':'unreadable_or_unstable','detail':str(e)});continue
            gid=linked.get(sid) or str(uuid.uuid5(uuid.NAMESPACE_URL,'claude-local-history:'+sid))
            local='local_'+str(uuid.uuid5(uuid.NAMESPACE_URL,'claude-history:'+profile+':'+sid))
            record={k:v for k,v in summary.items() if k not in ('signature','planNames')}
            source_meta=HISTORY_META.get(sid,{})
            for key in ('title','titleSource','createdAt','lastActivityAt','isArchived','cwd','originCwd'):
                if key in source_meta:record[key]=source_meta[key]
            record.update(sessionId=local,cliSessionId=sid,priorCliSessionIds=source_meta.get('priorCliSessionIds', []),permissionMode='default',
                          model=getattr(module,'PROFILE_MODELS',{}).get(profile,'mythos-magpie-1026517788' if profile=='magpie' else 'sonnet'),
                          originCwd=record.get('originCwd',record['cwd']),isArchived=record.get('isArchived',False),
                          threeAppSync={'group':gid,'historyImport':True})
            if profile in module.NAMES:
                record_path=module.account_dir(profile)/(local+'.json')
            else:record_path=path
            out.append((profile,record_path,record,summary['signature'],gid))
            scanned.add(sid)
    return out,scanned


def persist(module, tx):
    tx.write(module.ROOT/'history-index.json',module.json_bytes({'version':1,'paths':PATH_CACHE}))
    audit={'sources':SOURCE_STATS,'warnings':WARNINGS}
    tx.write(module.ROOT/'history-audit.json',module.json_bytes(audit))
