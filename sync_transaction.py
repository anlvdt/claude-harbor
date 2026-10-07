"""Write-ahead rollback journal. Recovery requires the caller's exclusive lock."""
import json
import os
import time
import uuid
from pathlib import Path
from safe_io import atomic_write, contained, digest, fsync_dir, private_dir, stable_read


def encoded(value): return (json.dumps(value, sort_keys=True, indent=2) + '\n').encode()


class Transaction:
    def __init__(self, data_root):
        self.data_root = Path(data_root).absolute()
        self.root = self.data_root / 'sync-backups' / (time.strftime('%Y%m%d-%H%M%S') + '-' + uuid.uuid4().hex)
        private_dir(self.root)
        self.entries = []; self.changes = []; self.expected = {}; self.guards = {}
        self.state = 'active'
        self.report()

    def report(self):
        atomic_write(self.root / 'journal.json', encoded({'version': 1, 'state': self.state, 'entries': self.entries}))
        atomic_write(self.root / 'paths.json', encoded([
            {'path': e['path'], 'backup': str(self.root/e['backup']) if e['backup'] else None}
            for e in self.entries]))

    def log_entry(self, index):
        path=self.root/'entries.jsonl'
        created=not path.exists()
        fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_APPEND|os.O_NOFOLLOW,0o600)
        try:
            with os.fdopen(fd,'ab',closefd=False) as log:
                log.write((json.dumps({'index':index,'entry':self.entries[index]},sort_keys=True)+'\n').encode())
                log.flush(); os.fsync(log.fileno())
        finally: os.close(fd)
        if created: fsync_dir(self.root)

    def write(self, path, data):
        path = contained(path, self.data_root)
        before = stable_read(path, self.data_root)[0] if path.exists() else None
        actual = digest(before) if before is not None else None
        guarded = self.expected.get(str(path), self.guards.get(str(path)))
        if str(path) in self.guards and actual != guarded:
            raise ValueError('Source changed before write: ' + str(path))
        if before == data: return
        prior = next((e for e in self.entries if e['path'] == str(path)), None)
        if prior is not None:
            prior.setdefault('attempted', [prior['after']]).append(digest(data))
            prior['after'] = digest(data)
            self.log_entry(self.entries.index(prior))
            atomic_write(path, data); self.expected[str(path)] = digest(data)
            return
        backup = str(len(self.entries)) if before is not None else None
        if backup is not None: atomic_write(self.root / backup, before)
        entry = {'path': str(path), 'backup': backup, 'before': digest(before) if before is not None else None,
                 'after': digest(data)}
        self.entries.append(entry); self.changes.append((path, self.root/backup if backup else None))
        self.log_entry(len(self.entries)-1)  # Intent and backup durable BEFORE the target.
        atomic_write(path, data)
        self.expected[str(path)] = digest(data)

    def commit(self):
        self.report()
        self.state = 'committed'
        atomic_write(self.root/'journal.json', encoded({'version':1,'state':self.state,'entries':self.entries}))

    def rollback(self):
        rollback(self.data_root, self.root, self.entries)
        self.state = 'rolled_back'; self.report()


def rollback(data_root, journal_root, entries):
    # Validate the complete recovery plan before the first mutation.
    for e in entries:
        contained(e['path'], data_root)
        if e['backup'] is not None:
            b = contained(journal_root/e['backup'], journal_root)
            if digest(stable_read(b, journal_root)[0]) != e['before']:
                raise ValueError('Corrupt recovery backup: ' + str(b))
    for index in reversed(range(len(entries))):
        e = entries[index]; path = Path(e['path'])
        current = stable_read(path, data_root)[0] if path.exists() else None
        current_hash = digest(current) if current is not None else None
        if current_hash == e['before']: continue  # Retry after interrupted rollback.
        if current_hash not in e.get('attempted', [e['after']]):
            raise ValueError('Recovery blocked: destination changed: ' + str(path))
        if e['backup'] is not None:
            atomic_write(path, stable_read(journal_root/e['backup'], journal_root)[0])
        elif path.exists():
            atomic_write(journal_root/('rolled-back-' + str(index)), current)
            path.unlink(); fsync_dir(path.parent)


def pending(data_root):
    """Fail closed before launch; recovery itself needs an exclusive store lock."""
    for directory in (Path(data_root)/'sync-backups').glob('*'):
        if not directory.is_dir(): continue
        contained(directory, data_root)
        journal=directory/'journal.json'
        if journal.exists():
            value=json.loads(stable_read(journal,data_root)[0])
            if value.get('version')!=1 or value.get('state') not in ('committed','rolled_back'):
                return True
        elif any(directory.iterdir()) and not (directory/'paths.json').exists():
            return True
    return False


def recover(data_root):
    recovered = []
    for directory in sorted((Path(data_root)/'sync-backups').glob('*')):
        if not directory.is_dir(): continue
        contained(directory, data_root)
        journal = directory/'journal.json'
        if not journal.exists():
            # Old releases have only paths.json. Never guess a legacy transaction's outcome.
            if any(directory.iterdir()) and not (directory/'paths.json').exists():
                raise ValueError('Legacy incomplete backup needs manual recovery: ' + str(directory))
            continue
        data = json.loads(stable_read(journal, data_root)[0])
        if data.get('version') != 1 or data.get('state') not in ('active', 'committed', 'rolled_back'):
            raise ValueError('Unsupported recovery journal: ' + str(journal))
        if data['state'] != 'active': continue
        log=directory/'entries.jsonl'
        if log.exists():
            entries=[]
            for line in stable_read(log,data_root)[0].splitlines(keepends=True):
                if not line.endswith(b'\n'): break  # A torn final intent cannot have reached its write.
                row=json.loads(line); index=row['index']; entry=row['entry']
                if not isinstance(index,int) or index<0 or index>len(entries): raise ValueError('Invalid journal sequence')
                if index==len(entries): entries.append(entry)
                else: entries[index]=entry
            data['entries']=entries
        rollback(Path(data_root), directory, data['entries'])
        data['state'] = 'rolled_back'; atomic_write(journal, encoded(data)); recovered.append(str(directory))
    return recovered
