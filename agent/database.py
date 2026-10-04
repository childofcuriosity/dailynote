import sqlite3
import os
import json
import uuid
import threading
from datetime import datetime
from config import DATABASE_PATH, DATA_DIR

_local = threading.local()


def get_db() -> sqlite3.Connection:
    """线程安全的数据库连接"""
    if not hasattr(_local, 'conn') or _local.conn is None:
        os.makedirs(DATA_DIR, exist_ok=True)
        conn = sqlite3.connect(DATABASE_PATH)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA foreign_keys=ON")
        _local.conn = conn
    return _local.conn


def init_db():
    """建表，幂等"""
    db = get_db()
    db.executescript("""
        CREATE TABLE IF NOT EXISTS conversations (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL DEFAULT '新对话',
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

    # 清理旧表
    try:
        db.execute('DROP TABLE IF EXISTS explorer_log')
    except Exception:
        pass

    # 迁移：旧表可能没有 reasoning 列
    _migrate(db)
    db.commit()


def _migrate(db: sqlite3.Connection):
    """补齐旧表缺少的列"""
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
    # 返回全部会话，由客户端（Flutter）自己过滤 hidden
    return [dict(r) for r in db.execute(
        'SELECT * FROM conversations ORDER BY last_active_at DESC').fetchall()]


def get_conversation(conv_id: str) -> dict | None:
    db = get_db()
    r = db.execute('SELECT * FROM conversations WHERE id = ?', (conv_id,)).fetchone()
    return dict(r) if r else None


def create_conversation(title: str = '新对话', source: str = 'user') -> dict:
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
    """今天之前创建、5分钟未活跃、未归档、非隐藏、仅用户会话"""
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
        # archived 标记未设，或归档后有新消息
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
        return {'id': '', 'role': 'system', 'content': ''}  # system 不进 DB
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
    """拷贝消息到目标会话，保留原始 created_at 和 reasoning"""
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
    """找最后一条是 user 消息的会话（AI 还没回复）"""
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
    """取最近 N 条消息，用于 AI 上下文"""
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
    # 自动生成 name（如果没有提供）
    if not name:
        name = mid[:8]
    db.execute(
        'INSERT INTO memories (id, name, description, type, content, source_conv_id, created_at, updated_at) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
        (mid, name, description, mem_type, content, source_conv_id, now, now))
    db.commit()
    return mid


def load_memory(mid: str) -> dict | None:
    """读取单条记忆全文"""
    db = get_db()
    r = db.execute('SELECT * FROM memories WHERE id = ?', (mid,)).fetchone()
    return dict(r) if r else None


def update_memory(mid: str, content: str, name: str | None = None,
                  description: str | None = None, mem_type: str | None = None):
    db = get_db()
    sets = ['content = ?', 'updated_at = ?']
    vals = [content, now_ms()]
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
    """独立的创建标签（不查重），返回 id"""
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


