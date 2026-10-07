"""Private atomic files and stable, contained reads for local profile data."""
import hashlib
import json
import os
import stat
import tempfile
from pathlib import Path


def contained(path, root):
    path = Path(os.path.abspath(path)); root = Path(os.path.abspath(root))
    try: parts = path.relative_to(root).parts
    except ValueError: raise ValueError('Path outside data root: ' + str(path))
    current = root
    if current.is_symlink(): raise ValueError('Symlink data root: ' + str(root))
    for part in parts:
        current = current / part
        if current.is_symlink(): raise ValueError('Symlink is not allowed: ' + str(current))
    return path


def private_dir(path):
    path = Path(path)
    missing = []
    p = path
    while not p.exists(): missing.append(p); p = p.parent
    for p in reversed(missing):
        p.mkdir(mode=0o700)
        fsync_dir(p.parent)


def fsync_dir(path):
    fd = os.open(path, os.O_RDONLY)
    try: os.fsync(fd)
    finally: os.close(fd)


def atomic_write(path, data):
    path = Path(path)
    if path.is_symlink(): raise ValueError('Symlink destination: ' + str(path))
    private_dir(path.parent)
    fd, name = tempfile.mkstemp(prefix='.' + path.name + '-', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as f:
            f.write(data); f.flush(); os.fsync(f.fileno())
        os.replace(name, path)
        fsync_dir(path.parent)
    finally:
        if os.path.exists(name): os.unlink(name)


def digest(data): return hashlib.sha256(data).hexdigest()


def parse_json(data, path, line_offset=0):
    """Keep decode errors actionable without including private JSON contents."""
    try:
        return json.loads(data)
    except json.JSONDecodeError as error:
        raise ValueError(f'Invalid JSON: {path}: line {error.lineno + line_offset} '
                         f'column {error.colno}: {error.msg}') from error
    except UnicodeError as error:
        raise ValueError(f'Invalid JSON encoding: {path}') from error


def transcript_rows(data, path):
    try:
        text = data.decode('utf-8')
    except UnicodeError as error:
        raise ValueError(f'Invalid transcript encoding: {path}') from error
    for line_number, line in enumerate(text.splitlines(), 1):
        if not line.strip(): continue
        row = parse_json(line, path, line_offset=line_number - 1)
        if not isinstance(row, dict):
            raise ValueError(f'Invalid transcript row: {path}: line {line_number}')
        yield row


def stable_read(path, root):
    path = contained(path, root)
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode): raise ValueError('Not a regular file: ' + str(path))
        with os.fdopen(fd, 'rb', closefd=False) as f: data = f.read()
        after = os.fstat(fd); current = path.stat()
        identity = lambda s: (s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns, s.st_ctime_ns)
        if identity(before) != identity(after) or identity(after) != identity(current):
            raise ValueError('Source changed while reading: ' + str(path))
        return data, before.st_mtime_ns
    finally: os.close(fd)
