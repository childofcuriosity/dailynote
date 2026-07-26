import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:uuid/uuid.dart';
import '../models/conversation.dart';
import '../models/message.dart';

class DatabaseService {
  static Database? _db;
  static const _uuid = Uuid();

  Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await _initDB();
    return _db!;
  }

  Future<Database> _initDB() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'dailynote.db');

    return await openDatabase(
      path,
      version: 8,
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
      },
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE tags (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        uuid TEXT NOT NULL UNIQUE,
        name TEXT NOT NULL UNIQUE,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      );
    ''');
    await db.execute('''
      CREATE TABLE conversation_tags (
        conversation_id INTEGER NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
        tag_id INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
        PRIMARY KEY (conversation_id, tag_id)
      );
    ''');
    await db.execute('''
      CREATE TABLE conversations (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        uuid TEXT NOT NULL UNIQUE,
        title TEXT NOT NULL,
        summary TEXT,
        user_note TEXT,
        forked_from INTEGER,
        forked_from_uuid TEXT,
        created_at INTEGER NOT NULL,
        last_active_at INTEGER NOT NULL,
        last_archived_at INTEGER,
        updated_at INTEGER NOT NULL
      );
    ''');
    await db.execute('''
      CREATE TABLE messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        uuid TEXT NOT NULL UNIQUE,
        conversation_id INTEGER REFERENCES conversations(id) ON DELETE CASCADE,
        conversation_uuid TEXT,
        role TEXT NOT NULL CHECK(role IN ('user', 'assistant')),
        content TEXT NOT NULL,
        parent_id INTEGER REFERENCES messages(id) ON DELETE SET NULL,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      );
    ''');
    await db.execute('''
      CREATE TABLE memories (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        uuid TEXT NOT NULL UNIQUE,
        content TEXT NOT NULL,
        source_conv_id INTEGER REFERENCES conversations(id) ON DELETE SET NULL,
        source_conv_uuid TEXT,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      );
    ''');
    await db.execute('CREATE INDEX idx_memories_content ON memories(content)');
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await db.execute('ALTER TABLE conversations ADD COLUMN summary TEXT');
    }
    if (oldVersion < 3) {
      await db.execute('ALTER TABLE conversations ADD COLUMN user_note TEXT');
      await db.execute(
          'ALTER TABLE conversations ADD COLUMN last_active_at INTEGER');
      await db.execute(
          'UPDATE conversations SET last_active_at = created_at WHERE last_active_at IS NULL');
      await db.execute('''CREATE TABLE memories (id INTEGER PRIMARY KEY AUTOINCREMENT, content TEXT NOT NULL, source_conv_id INTEGER REFERENCES conversations(id) ON DELETE SET NULL, created_at INTEGER NOT NULL);''');
      await db.execute(
          'CREATE INDEX idx_memories_content ON memories(content)');
    }
    if (oldVersion < 4) {
      await db.execute(
          'ALTER TABLE conversations ADD COLUMN last_archived_at INTEGER');
    }
    if (oldVersion < 5) {
      await db.execute(
          'ALTER TABLE messages ADD COLUMN parent_id INTEGER REFERENCES messages(id) ON DELETE SET NULL');
    }
    if (oldVersion < 6) {
      await db.execute(
          'ALTER TABLE conversations ADD COLUMN forked_from INTEGER');
    }
    if (oldVersion < 7) {
      await _migrateV7(db);
    }
    if (oldVersion < 8) {
      await _migrateV8(db);
    }
  }

  Future<void> _migrateV7(Database db) async {
    await db.execute('''CREATE TABLE tags (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL UNIQUE, created_at INTEGER NOT NULL);''');
    await db.execute('''CREATE TABLE conversation_tags (conversation_id INTEGER NOT NULL REFERENCES conversations(id) ON DELETE CASCADE, tag_id INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE, PRIMARY KEY (conversation_id, tag_id));''');
    try {
      final convs = await db.query('conversations',
          columns: ['id', 'category'],
          where: "category IS NOT NULL AND category != '未分类'");
      for (final c in convs) {
        final name = c['category'] as String;
        if (name.isEmpty || name == '未分类') continue;
        var rows =
            await db.query('tags', where: 'name = ?', whereArgs: [name]);
        int tagId;
        if (rows.isEmpty) {
          tagId = await db.insert('tags',
              {'name': name, 'created_at': DateTime.now().millisecondsSinceEpoch});
        } else {
          tagId = rows.first['id'] as int;
        }
        await db.insert('conversation_tags',
            {'conversation_id': c['id'], 'tag_id': tagId},
            conflictAlgorithm: ConflictAlgorithm.ignore);
      }
    } catch (_) {}
  }

  /// v8: 加 uuid + updated_at，支持多设备同步
  Future<void> _migrateV8(Database db) async {
    final now = DateTime.now().millisecondsSinceEpoch;

    // --- conversations ---
    await db.execute('ALTER TABLE conversations ADD COLUMN uuid TEXT');
    await db.execute('ALTER TABLE conversations ADD COLUMN forked_from_uuid TEXT');
    await db.execute('ALTER TABLE conversations ADD COLUMN updated_at INTEGER');
    final convs = await db.query('conversations', columns: ['id']);
    for (final c in convs) {
      await db.update(
        'conversations',
        {'uuid': _uuid.v4(), 'updated_at': now},
        where: 'id = ?',
        whereArgs: [c['id']],
      );
    }

    // --- messages ---
    await db.execute('ALTER TABLE messages ADD COLUMN uuid TEXT');
    await db.execute('ALTER TABLE messages ADD COLUMN conversation_uuid TEXT');
    await db.execute('ALTER TABLE messages ADD COLUMN updated_at INTEGER');
    final msgs = await db.query('messages', columns: ['id']);
    for (final m in msgs) {
      await db.update(
        'messages',
        {'uuid': _uuid.v4(), 'updated_at': now},
        where: 'id = ?',
        whereArgs: [m['id']],
      );
    }

    // --- memories ---
    await db.execute('ALTER TABLE memories ADD COLUMN uuid TEXT');
    await db.execute('ALTER TABLE memories ADD COLUMN source_conv_uuid TEXT');
    await db.execute('ALTER TABLE memories ADD COLUMN updated_at INTEGER');
    final mems = await db.query('memories', columns: ['id']);
    for (final m in mems) {
      await db.update(
        'memories',
        {'uuid': _uuid.v4(), 'updated_at': now},
        where: 'id = ?',
        whereArgs: [m['id']],
      );
    }

    // --- tags ---
    await db.execute('ALTER TABLE tags ADD COLUMN uuid TEXT');
    await db.execute('ALTER TABLE tags ADD COLUMN updated_at INTEGER');
    final tags = await db.query('tags', columns: ['id']);
    for (final t in tags) {
      await db.update(
        'tags',
        {'uuid': _uuid.v4(), 'updated_at': now},
        where: 'id = ?',
        whereArgs: [t['id']],
      );
    }

    // 给已有数据补 foreign uuid（根据本地 id 查对应 uuid）
    await db.rawUpdate('''
      UPDATE messages SET conversation_uuid = (
        SELECT c.uuid FROM conversations c WHERE c.id = messages.conversation_id
      )
    ''');
    await db.rawUpdate('''
      UPDATE memories SET source_conv_uuid = (
        SELECT c.uuid FROM conversations c WHERE c.id = memories.source_conv_id
      )
    ''');
    await db.rawUpdate('''
      UPDATE conversations SET forked_from_uuid = (
        SELECT c.uuid FROM conversations c WHERE c.id = conversations.forked_from
      )
    ''');
  }

  // ========== UUID ↔ 本地 ID 映射 ==========

  Future<int?> getLocalIdByUuid(String table, String uuid) async {
    final db = await database;
    final rows = await db.query(table,
        columns: ['id'], where: 'uuid = ?', whereArgs: [uuid], limit: 1);
    return rows.isEmpty ? null : rows.first['id'] as int;
  }

  Future<String?> getUuidByLocalId(String table, int id) async {
    final db = await database;
    final rows = await db.query(table,
        columns: ['uuid'], where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : rows.first['uuid'] as String;
  }

  // ========== 标签 CRUD ==========

  Future<List<Map<String, dynamic>>> getTags() async {
    final db = await database;
    return await db.query('tags', orderBy: 'id ASC');
  }

  Future<int> createTag(String name) async {
    final db = await database;
    final trimmed = name.trim();
    if (trimmed.isEmpty) throw Exception('标签名不能为空');
    final existing =
        await db.query('tags', where: 'name = ?', whereArgs: [trimmed]);
    if (existing.isNotEmpty) return existing.first['id'] as int;
    final now = DateTime.now().millisecondsSinceEpoch;
    return await db.insert('tags', {
      'uuid': _uuid.v4(),
      'name': trimmed,
      'created_at': now,
      'updated_at': now,
    });
  }

  Future<int?> findTag(String name) async {
    final db = await database;
    final rows =
        await db.query('tags', where: 'name = ?', whereArgs: [name.trim()]);
    return rows.isEmpty ? null : rows.first['id'] as int;
  }

  Future<Map<String, dynamic>?> getTagByUuid(String uuid) async {
    final db = await database;
    final rows = await db.query('tags', where: 'uuid = ?', whereArgs: [uuid]);
    return rows.isEmpty ? null : rows.first;
  }

  Future<void> deleteTag(int tagId) async {
    final db = await database;
    await db.delete('tags', where: 'id = ?', whereArgs: [tagId]);
  }

  // ========== 会话-标签关联 ==========

  Future<void> setConversationTags(int convId, List<int> tagIds) async {
    final db = await database;
    await db.delete('conversation_tags',
        where: 'conversation_id = ?', whereArgs: [convId]);
    for (final tid in tagIds) {
      await db.insert('conversation_tags',
          {'conversation_id': convId, 'tag_id': tid},
          conflictAlgorithm: ConflictAlgorithm.ignore);
    }
  }

  Future<void> setConversationTagsByUuid(
      String convUuid, List<String> tagUuids) async {
    final convId = await getLocalIdByUuid('conversations', convUuid);
    if (convId == null) return;
    final tagIds = <int>[];
    for (final tu in tagUuids) {
      final tid = await getLocalIdByUuid('tags', tu);
      if (tid != null) tagIds.add(tid);
    }
    await setConversationTags(convId, tagIds);
  }

  Future<List<String>> getTagsForConversation(int convId) async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT t.name FROM tags t
      JOIN conversation_tags ct ON ct.tag_id = t.id
      WHERE ct.conversation_id = ?
    ''', [convId]);
    return rows.map((r) => r['name'] as String).toList();
  }

  Future<List<Map<String, dynamic>>> getConversationTagsForSync(
      String convUuid) async {
    final db = await database;
    final convId = await getLocalIdByUuid('conversations', convUuid);
    if (convId == null) return [];
    return await db.rawQuery('''
      SELECT t.uuid as tag_uuid FROM tags t
      JOIN conversation_tags ct ON ct.tag_id = t.id
      WHERE ct.conversation_id = ?
    ''', [convId]);
  }

  // ========== 会话 CRUD ==========

  Future<int> insertConversation(Conversation c) async {
    final db = await database;
    final map = c.toMap();
    // 自动填充 forked_from_uuid
    if (map['forked_from'] != null && map['forked_from_uuid'] == null) {
      map['forked_from_uuid'] =
          await getUuidByLocalId('conversations', map['forked_from'] as int);
    }
    return await db.insert('conversations', map);
  }

  Future<List<Conversation>> getConversations({List<int>? tagIds}) async {
    final db = await database;
    if (tagIds != null && tagIds.isNotEmpty) {
      final placeholders = tagIds.map((_) => '?').join(',');
      final rows = await db.rawQuery('''
        SELECT DISTINCT c.* FROM conversations c
        JOIN conversation_tags ct ON ct.conversation_id = c.id
        WHERE ct.tag_id IN ($placeholders)
        ORDER BY c.last_active_at DESC
      ''', tagIds);
      return rows.map((m) => Conversation.fromMap(m)).toList();
    }
    final List<Map<String, dynamic>> maps = await db.query(
      'conversations',
      orderBy: 'last_active_at DESC',
    );
    return maps.map((m) => Conversation.fromMap(m)).toList();
  }

  Future<Conversation?> getConversation(int id) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'conversations',
      where: 'id = ?',
      whereArgs: [id],
    );
    if (maps.isEmpty) return null;
    return Conversation.fromMap(maps.first);
  }

  Future<void> updateConversation(Conversation c) async {
    final db = await database;
    final map = c.toMap();
    map.remove('id');
    map['updated_at'] = DateTime.now().millisecondsSinceEpoch;
    await db.update('conversations', map,
        where: 'id = ?', whereArgs: [c.id]);
  }

  Future<void> deleteConversation(int id) async {
    final db = await database;
    await db.delete('conversations', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> touchConversation(int id) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.update('conversations',
        {'last_active_at': now, 'updated_at': now},
        where: 'id = ?',
        whereArgs: [id]);
  }

  Future<void> markArchived(int id) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.update('conversations',
        {'last_archived_at': now, 'updated_at': now},
        where: 'id = ?',
        whereArgs: [id]);
  }

  Future<List<Conversation>> getDirtyBeforeToday() async {
    final db = await database;
    final today = DateTime.now();
    final todayStart = DateTime(today.year, today.month, today.day);
    final todayStartMs = todayStart.millisecondsSinceEpoch;
    final fiveMinAgo = DateTime.now()
        .subtract(const Duration(minutes: 5))
        .millisecondsSinceEpoch;
    final List<Map<String, dynamic>> maps = await db.rawQuery('''
      SELECT * FROM conversations
      WHERE created_at < ? AND (last_archived_at IS NULL OR last_active_at > last_archived_at) AND last_active_at < ?
      ORDER BY last_active_at DESC
    ''', [todayStartMs, fiveMinAgo]);
    return maps.map((m) => Conversation.fromMap(m)).toList();
  }

  Future<List<Map<String, dynamic>>> searchConversations(String query) async {
    final db = await database;
    final keyword = '%$query%';
    final List<Map<String, dynamic>> maps = await db.rawQuery('''
      SELECT id, title, summary, user_note, created_at, last_active_at
      FROM conversations WHERE title LIKE ? OR summary LIKE ?
      ORDER BY last_active_at DESC LIMIT 10
    ''', [keyword, keyword]);
    return maps;
  }

  /// 会话总数
  Future<int> getConversationsRawCount() async {
    final db = await database;
    final result =
        await db.rawQuery('SELECT COUNT(*) as cnt FROM conversations');
    return result.first['cnt'] as int;
  }

  /// 返回所有对话的摘要索引（供 AI 自己筛选）
  Future<List<Map<String, dynamic>>> listAllConversations() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.rawQuery('''
      SELECT id, title, summary, user_note, created_at, last_active_at
      FROM conversations
      ORDER BY last_active_at DESC
    ''');
    return maps;
  }

  // ========== 消息 CRUD ==========

  Future<int> insertMessage(Message m) async {
    final db = await database;
    // 自动填充 conversation_uuid
    final map = m.toMap();
    if (map['conversation_uuid'] == null && map['conversation_id'] != null) {
      map['conversation_uuid'] =
          await getUuidByLocalId('conversations', map['conversation_id'] as int);
    }
    return await db.insert('messages', map);
  }

  Future<List<Message>> getMessages(int convId) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'messages',
      where: 'conversation_id = ?',
      whereArgs: [convId],
      orderBy: 'created_at ASC',
    );
    return maps.map((m) => Message.fromMap(m)).toList();
  }

  Future<void> copyMessagesBefore(
      int sourceConvId, int targetConvId, int count) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'messages',
      where: 'conversation_id = ?',
      whereArgs: [sourceConvId],
      orderBy: 'created_at ASC',
      limit: count,
    );
    final targetUuid = await getUuidByLocalId('conversations', targetConvId);
    for (final m in maps) {
      final now = DateTime.now().millisecondsSinceEpoch;
      await db.insert('messages', {
        'uuid': _uuid.v4(),
        'conversation_id': targetConvId,
        'conversation_uuid': targetUuid,
        'role': m['role'],
        'content': m['content'],
        'created_at': m['created_at'],
        'updated_at': now,
      });
    }
  }

  // ========== 记忆 CRUD ==========

  Future<int> insertMemory(String content, {int? sourceConvId}) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    String? sourceConvUuid;
    if (sourceConvId != null) {
      sourceConvUuid =
          await getUuidByLocalId('conversations', sourceConvId);
    }
    return await db.insert('memories', {
      'uuid': _uuid.v4(),
      'content': content,
      'source_conv_id': sourceConvId,
      'source_conv_uuid': sourceConvUuid,
      'created_at': now,
      'updated_at': now,
    });
  }

  Future<List<Map<String, dynamic>>> getAllMemories() async {
    final db = await database;
    return await db.query('memories', orderBy: 'created_at DESC');
  }

  Future<void> updateMemory(int id, String content) async {
    final db = await database;
    await db.update('memories', {'content': content},
        where: 'id = ?', whereArgs: [id]);
  }

  Future<void> deleteMemory(int id) async {
    final db = await database;
    await db.delete('memories', where: 'id = ?', whereArgs: [id]);
  }

  Future<List<String>> searchMemories(String query) async {
    final db = await database;
    final keyword = '%$query%';
    final List<Map<String, dynamic>> maps = await db.rawQuery(
      'SELECT content FROM memories WHERE content LIKE ? ORDER BY created_at DESC LIMIT 10',
      [keyword],
    );
    return maps.map((m) => m['content'] as String).toList();
  }

}
