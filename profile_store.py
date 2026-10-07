"""Profile registry: login data never travels between profiles."""
import json, os, uuid
from pathlib import Path
from safe_io import atomic_write, private_dir, parse_json
SUPPORT = Path.home() / 'Library/Application Support'
LEGACY = SUPPORT / 'ClaudeThreeDesktop'
ROOT = LEGACY if (LEGACY / 'profiles.json').exists() else SUPPORT / 'ClaudeHarbor'
REGISTRY = ROOT / 'profiles.json'

def defaults():
    return []

def load():
    if not REGISTRY.exists(): return []
    data = parse_json(REGISTRY.read_bytes(), REGISTRY)
    if not isinstance(data, dict) or data.get('version', 1) != 1 or not isinstance(data.get('profiles'), list):
        raise ValueError('Registry schema không được hỗ trợ')
    profiles = data['profiles']; seen = set()
    for p in profiles:
        if not isinstance(p, dict) or not isinstance(p.get('id'), str) or not p['id'].replace('-', '').isalnum():
            raise ValueError('Profile ID không hợp lệ')
        if p['id'] in seen: raise ValueError('Profile ID trùng lặp')
        seen.add(p['id'])
        if 'syncEnabled' in p and not isinstance(p['syncEnabled'], bool): raise ValueError('Invalid sync selection')
        if 'kind' in p and p['kind'] not in ('claude', 'magpie'): raise ValueError('Invalid profile kind')
    return profiles


def save(profiles):
    private_dir(ROOT)
    if REGISTRY.exists(): atomic_write(ROOT/'profiles.previous.json', REGISTRY.read_bytes())
    atomic_write(REGISTRY, (json.dumps({'version':1,'profiles':profiles},ensure_ascii=False,indent=2)+'\n').encode())

def gui(p): return ROOT/'profiles'/p['id']/('gui-3p' if p['kind']=='magpie' else 'gui')

def account(p):
    g=gui(p); config=g/'config.json'
    data=parse_json(config.read_bytes(), config) if config.exists() else {}
    current=data.get('lastKnownAccountUuid')
    legacy=p.get('legacyAccount')
    if legacy:
        f=Path.home()/'.config/magpie/claude-accounts'/legacy/'.claude.json'
        if f.exists():
            a=parse_json(f.read_bytes(), f).get('oauthAccount',{})
            if current and current!=a.get('accountUuid'): legacy=None
            else:
                return g/'claude-code-sessions'/str(uuid.UUID(a['accountUuid']))/str(uuid.UUID(a['organizationUuid']))
    base=g/'claude-code-sessions'
    if current:
        base=base/str(uuid.UUID(current))
        orgs=[d for d in base.iterdir() if d.is_dir()] if base.exists() else []
    else:
        # The 3P deployment has its own synthetic account, supplied by Desktop.
        if p['kind']!='magpie': raise ValueError('Đăng nhập và mở tab Code một lần để bật đồng bộ.')
        origins=list(base.glob('*/*.profile-origin.json'))
        if len(origins)!=1: raise ValueError('Mở tab Code một lần để bật đồng bộ.')
        return origins[0].parent/origins[0].name.removesuffix('.profile-origin.json')
    if not orgs: raise ValueError('Mở tab Code và tạo một phiên local để bật đồng bộ.')
    return max(orgs,key=lambda d:max((f.stat().st_mtime for f in d.glob('local_*.json')),default=d.stat().st_mtime))
