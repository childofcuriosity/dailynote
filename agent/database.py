import sqlite3
import os
import json
import uuid
import threading
from datetime import datetime
from config import DATABASE_PATH, DATA_DIR
from account_context import database_path
from i18n import tr

_local = threading.local()


def get_db() -> sqlite3.Connection:
    """Return a thread-local connection for the current account."""
    path = database_path()
    if not hasattr(_local, 'connections'):
        _local.connections = {}
    if path not in _local.connections:
        os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
        conn = sqlite3.connect(path)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA foreign_keys=ON")
        _local.connections[path] = conn
    return _local.connections[path]


def close_db():
    for conn in getattr(_local, 'connections', {}).values():
        conn.close()
    _local.connections = {}


def init_db():
    """Create missing tables and columns idempotently."""
    db = get_db()
    db.executescript("""
        CREATE TABLE IF NOT EXISTS scheduler_state (
            name TEXT PRIMARY KEY,
            timestamp REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS conversations (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL DEFAULT 'New conversation',
            summary TEXT,
            user_note TEXT,
            forked_from TEXT,
            source TEXT NOT NULL DEFAULT 'user',
            pinned INTEGER NOT NULL DEFAULT 0,
            hidden INTEGER NOT NULL DEFAULT 0,
            archived INTEGER NOT NULL DEFAULT 0,
            created_at INTEGER NOT NULL,
            last_active_at INTEGER NOT NULL,
            last_archived_at INTEGER,
            updated_at INTEGER NOT NULL
        );

        CREATE TABLE IF NOT EXISTS messages (
            id TEXT PRIMARY KEY,
            conversation_id TEXT NOT NULL,
            role TEXT NOT NULL CHECK(role IN ('user', 'assistant', 'system', 'tool')),
            content TEXT NOT NULL DEFAULT '',
            reasoning TEXT,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            FOREIGN KEY (conversation_id) REFERENCES conversations(id) ON DELETE CASCADE
        );

        CREATE INDEX IF NOT EXISTS idx_messages_conv ON messages(conversation_id, created_at);

        CREATE TABLE IF NOT EXISTS memories (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL DEFAULT '',
            description TEXT NOT NULL DEFAULT '',
            type TEXT NOT NULL DEFAULT 'fact',
            content TEXT NOT NULL,
            source_conv_id TEXT,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
        );

        CREATE TABLE IF NOT EXISTS tags (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL UNIQUE,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
        );

        CREATE TABLE IF NOT EXISTS conversation_tags (
            conversation_id TEXT NOT NULL,
            tag_id TEXT NOT NULL,
            PRIMARY KEY (conversation_id, tag_id),
            FOREIGN KEY (conversation_id) REFERENCES conversations(id) ON DELETE CASCADE,
            FOREIGN KEY (tag_id) REFERENCES tags(id) ON DELETE CASCADE
        );

    """)

    # Clean up old tables
    try:
        db.execute('DROP TABLE IF EXISTS explorer_log')
    except Exception:
        pass

    # Migration: Old tables may not have a reasoning column
    _migrate(db)
    db.commit()


def _migrate(db: sqlite3.Connection):
    """Add columns missing from older databases."""
    cols = {r[1] for r in db.execute('PRAGMA table_info(messages)').fetchall()}
    if 'reasoning' not in cols:
        db.execute('ALTER TABLE messages ADD COLUMN reasoning TEXT')
    cols = {r[1] for r in db.execute('PRAGMA table_info(conversations)').fetchall()}
    if 'source' not in cols:
        db.execute('ALTER TABLE conversations ADD COLUMN source TEXT NOT NULL DEFAULT "user"')
    cols = {r[1] for r in db.execute('PRAGMA table_info(memories)').fetchall()}
    if 'name' not in cols:
        db.execute('ALTER TABLE memories ADD COLUMN name TEXT NOT NULL DEFAULT ""')
    if 'description' not in cols:
        db.execute('ALTER TABLE memories ADD COLUMN description TEXT NOT NULL DEFAULT ""')
    if 'type' not in cols:
        db.execute('ALTER TABLE memories ADD COLUMN type TEXT NOT NULL DEFAULT "fact"')
    cols = {r[1] for r in db.execute('PRAGMA table_info(conversations)').fetchall()}
    if 'archived' not in cols:
        db.execute('ALTER TABLE conversations ADD COLUMN archived INTEGER NOT NULL DEFAULT 0')


def get_schedule_time(name: str) -> float | None:
    row = get_db().execute('SELECT timestamp FROM scheduler_state WHERE name = ?', (name,)).fetchone()
    return float(row[0]) if row else None


def set_schedule_time(name: str, timestamp: float):
    db = get_db()
    db.execute('INSERT INTO scheduler_state (name, timestamp) VALUES (?, ?) '
               'ON CONFLICT(name) DO UPDATE SET timestamp = excluded.timestamp', (name, timestamp))
    db.commit()


def latest_exploration_time() -> float | None:
    row = get_db().execute("SELECT MAX(created_at) FROM conversations WHERE source IN ('explore_raw', 'explorer')").fetchone()
    return row[0] / 1000 if row and row[0] is not None else None


def now_ms() -> int:
    return int(datetime.now().timestamp() * 1000)


def new_id() -> str:
    return uuid.uuid4().hex[:12]


# ========== Conversations ==========

def list_conversations(source: str | None = None) -> list[dict]:
    db = get_db()
    if source:
        return [dict(r) for r in db.execute(
            'SELECT * FROM conversations WHERE source = ? ORDER BY last_active_at DESC',
            (source,)).fetchall()]
    # Return all sessions; the client (Flutter) filters hidden itself
    return [dict(r) for r in db.execute(
        'SELECT * FROM conversations ORDER BY last_active_at DESC').fetchall()]


def get_conversation(conv_id: str) -> dict | None:
    db = get_db()
    r = db.execute('SELECT * FROM conversations WHERE id = ?', (conv_id,)).fetchone()
    return dict(r) if r else None


def create_conversation(title: str | None = None, source: str = 'user') -> dict:
    title = title if title is not None else tr('New conversation')
    db = get_db()
    cid = new_id()
    now = now_ms()
    db.execute(
        'INSERT INTO conversations (id, title, source, created_at, last_active_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)',
        (cid, title, source, now, now, now))
    db.commit()
    return {'id': cid, 'title': title, 'source': source, 'created_at': now, 'last_active_at': now}


def update_conversation(conv_id: str, **kwargs):
    db = get_db()
    allowed = {'title', 'summary', 'user_note', 'forked_from', 'source',
               'pinned', 'hidden', 'archived', 'created_at', 'last_active_at',
               'last_archived_at'}
    kwargs = {key: value for key, value in kwargs.items() if key in allowed}
    if not kwargs:
        return
    kwargs['updated_at'] = now_ms()
    sets = ', '.join(f'{k} = ?' for k in kwargs)
    vals = list(kwargs.values()) + [conv_id]
    db.execute(f'UPDATE conversations SET {sets} WHERE id = ?', vals)
    db.commit()


def touch_conversation(conv_id: str):
    db = get_db()
    now = now_ms()
    db.execute('UPDATE conversations SET last_active_at = ?, updated_at = ? WHERE id = ?',
               (now, now, conv_id))
    db.commit()


def get_dirty_conversations() -> list[dict]:
    """Select visible, unarchived user conversations created before today and idle for five minutes."""
    today_start_ms = int(datetime.now().replace(hour=0, minute=0, second=0, microsecond=0).timestamp() * 1000)
    five_min_ago_ms = now_ms() - 5 * 60 * 1000

    db = get_db()
    rows = db.execute(
        'SELECT * FROM conversations '
        'WHERE created_at < ? AND last_active_at < ? '
        'AND hidden = 0 AND source = "user" '
        'ORDER BY last_active_at DESC',
        (today_start_ms, five_min_ago_ms)).fetchall()

    results = []
    for r in rows:
        d = dict(r)
        last_archived = d.get('last_archived_at')
        last_active = d['last_active_at']
        # archived flag is not set, or there are new messages after archiving
        if not d.get('archived') or last_active > (last_archived or 0):
            results.append(d)
    return results


def delete_conversation(conv_id: str):
    db = get_db()
    db.execute('DELETE FROM conversations WHERE id = ?', (conv_id,))
    db.commit()


def get_conversation_count() -> int:
    db = get_db()
    return db.execute('SELECT COUNT(*) FROM conversations').fetchone()[0]


# ========== Messages ==========

def list_messages(conv_id: str) -> list[dict]:
    db = get_db()
    rows = db.execute(
        'SELECT * FROM messages WHERE conversation_id = ? ORDER BY created_at ASC',
        (conv_id,)).fetchall()
    return [dict(r) for r in rows]


def insert_message(conv_id: str, role: str, content: str, reasoning: str | None = None) -> dict:
    if role == 'system':
        return {'id': '', 'role': 'system', 'content': ''}  # system is not stored in the DB
    db = get_db()
    mid = new_id()
    now = now_ms()
    db.execute(
        'INSERT INTO messages (id, conversation_id, role, content, reasoning, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)',
        (mid, conv_id, role, content, reasoning, now, now))
    touch_conversation(conv_id)
    db.commit()
    return {'id': mid, 'conversation_id': conv_id, 'role': role, 'content': content,
            'reasoning': reasoning, 'created_at': now}


def copy_message(orig_id: str, target_conv_id: str):
    """Copy a message, preserving its timestamp and reasoning."""
    db = get_db()
    orig = db.execute('SELECT * FROM messages WHERE id = ?', (orig_id,)).fetchone()
    if not orig:
        return
    mid = new_id()
    db.execute(
        'INSERT INTO messages (id, conversation_id, role, content, reasoning, created_at, updated_at) '
        'VALUES (?, ?, ?, ?, ?, ?, ?)',
        (mid, target_conv_id, orig['role'], orig['content'], orig['reasoning'],
         orig['created_at'], now_ms()))
    db.commit()


def get_last_message(conv_id: str) -> dict | None:
    db = get_db()
    r = db.execute(
        'SELECT * FROM messages WHERE conversation_id = ? ORDER BY created_at DESC LIMIT 1',
        (conv_id,)).fetchone()
    return dict(r) if r else None


def get_unreplied_conversations() -> list[str]:
    """Find conversations whose most recent message needs a reply."""
    db = get_db()
    rows = db.execute("""
        SELECT m.conversation_id FROM messages m
        INNER JOIN (
            SELECT conversation_id, MAX(created_at) AS max_ts
            FROM messages GROUP BY conversation_id
        ) latest ON m.conversation_id = latest.conversation_id AND m.created_at = latest.max_ts
        WHERE m.role = 'user'
        ORDER BY m.created_at ASC
    """).fetchall()
    return [r[0] for r in rows]


def get_recent_conversation_context(conv_id: str, limit: int = 1000) -> list[dict]:
    """Load the most recent N messages for model context."""
    db = get_db()
    rows = db.execute(
        'SELECT * FROM messages WHERE conversation_id = ? ORDER BY created_at DESC LIMIT ?',
        (conv_id, limit)).fetchall()
    rows = list(reversed(rows))
    return [dict(r) for r in rows]


# ========== Memories ==========

def list_memories() -> list[dict]:
    db = get_db()
    rows = db.execute('SELECT * FROM memories ORDER BY created_at DESC').fetchall()
    return [dict(r) for r in rows]


def list_memory_contents() -> list[str]:
    db = get_db()
    rows = db.execute('SELECT content FROM memories ORDER BY created_at DESC').fetchall()
    return [r[0] for r in rows]


def insert_memory(content: str, source_conv_id: str | None = None,
                   name: str = '', description: str = '', mem_type: str = 'fact') -> str:
    db = get_db()
    mid = new_id()
    now = now_ms()
    # Auto-generate name (if not provided)
    if not name:
        name = mid[:8]
    db.execute(
        'INSERT INTO memories (id, name, description, type, content, source_conv_id, created_at, updated_at) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
        (mid, name, description, mem_type, content, source_conv_id, now, now))
    db.commit()
    return mid


def load_memory(mid: str) -> dict | None:
    """Read one full memory."""
    db = get_db()
    r = db.execute('SELECT * FROM memories WHERE id = ?', (mid,)).fetchone()
    return dict(r) if r else None


def update_memory(mid: str, content: str | None = None, name: str | None = None,
                  description: str | None = None, mem_type: str | None = None):
    db = get_db()
    sets = ['updated_at = ?']
    vals = [now_ms()]
    if content is not None:
        sets.append('content = ?')
        vals.append(content)
    if name is not None:
        sets.append('name = ?')
        vals.append(name)
    if description is not None:
        sets.append('description = ?')
        vals.append(description)
    if mem_type is not None:
        sets.append('type = ?')
        vals.append(mem_type)
    vals.append(mid)
    db.execute(f'UPDATE memories SET {", ".join(sets)} WHERE id = ?', vals)
    db.commit()


def delete_memory(mid: str):
    db = get_db()
    db.execute('DELETE FROM memories WHERE id = ?', (mid,))
    db.commit()


# ========== Tags ==========

def list_tags() -> list[dict]:
    db = get_db()
    rows = db.execute('SELECT * FROM tags ORDER BY name').fetchall()
    return [dict(r) for r in rows]


def get_or_create_tag(name: str) -> str:
    db = get_db()
    r = db.execute('SELECT id FROM tags WHERE name = ?', (name.strip(),)).fetchone()
    if r:
        return r[0]
    tid = new_id()
    now = now_ms()
    db.execute('INSERT INTO tags (id, name, created_at, updated_at) VALUES (?, ?, ?, ?)',
               (tid, name.strip(), now, now))
    db.commit()
    return tid


def create_tag(name: str) -> str:
    """Create a tag and return its ID."""
    return get_or_create_tag(name)


def delete_tag(tag_id: str):
    db = get_db()
    db.execute('DELETE FROM conversation_tags WHERE tag_id = ?', (tag_id,))
    db.execute('DELETE FROM tags WHERE id = ?', (tag_id,))
    db.commit()


def set_conversation_tags(conv_id: str, tag_names: list[str]):
    db = get_db()
    db.execute('DELETE FROM conversation_tags WHERE conversation_id = ?', (conv_id,))
    for name in tag_names:
        tid = get_or_create_tag(name)
        db.execute('INSERT OR IGNORE INTO conversation_tags (conversation_id, tag_id) VALUES (?, ?)',
                   (conv_id, tid))
    db.commit()


def get_conversation_tags(conv_id: str) -> list[str]:
    db = get_db()
    rows = db.execute("""
        SELECT t.name FROM tags t
        INNER JOIN conversation_tags ct ON t.id = ct.tag_id
        WHERE ct.conversation_id = ?
    """, (conv_id,)).fetchall()
    return [r[0] for r in rows]


