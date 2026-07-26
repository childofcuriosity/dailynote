import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import '../models/conversation.dart';
import '../models/message.dart';

class SupaService {
  final SupabaseClient _c;
  static const _uuid = Uuid();

  SupaService(this._c);

  // ========== Conversations ==========

  Future<List<Conversation>> getConversations({List<String>? tagIds}) async {
    var query = _c.from('conversations').select().order('last_active_at', ascending: false);
    // tag filter not used in current flow
    final data = await query;
    return (data as List).map((r) => Conversation.fromSupabase(r)).toList().cast<Conversation>();
  }

  Future<Conversation?> getConversation(String id) async {
    final data = await _c.from('conversations').select().eq('id', id).maybeSingle();
    if (data == null) return null;
    return Conversation.fromSupabase(data);
  }

  Future<String> insertConversation(Conversation c) async {
    final map = c.toSupabase();
    await _c.from('conversations').insert(map);
    return map['id'] as String;
  }

  Future<void> updateConversation(Conversation c) async {
    await _c.from('conversations').update(c.toSupabase()).eq('id', c.uuid);
  }

  Future<void> deleteConversation(String id) async {
    await _c.from('conversations').delete().eq('id', id);
  }

  Future<List<Conversation>> getDirtyBeforeToday() async {
    // 查今天之前创建、且未归档或归档后有新消息的
    final todayStart = DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day);
    final fiveMinAgo = DateTime.now().subtract(const Duration(minutes: 5));
    final fiveMinAgoMs = fiveMinAgo.millisecondsSinceEpoch;
    final todayStartMs = todayStart.millisecondsSinceEpoch;

    // 先查出昨天之前的所有对话，在本地过滤
    final data = await _c.from('conversations').select()
        .lt('created_at', todayStartMs.toString())
        .order('last_active_at', ascending: false);

    final results = <Conversation>[];
    for (final r in data as List) {
      final conv = Conversation.fromSupabase(r);
      if (conv.lastActiveAt.millisecondsSinceEpoch < fiveMinAgoMs && conv.isDirty) {
        results.add(conv);
      }
    }
    return results;
  }

  Future<int> getConversationsCount() async {
    final data = await _c.from('conversations').select('id').limit(0);
    // Supabase doesn't support count directly with select; approximate with data length workaround
    return (data as List).length;
  }

  // ========== Messages ==========

  Future<List<Message>> getMessages(String convId) async {
    final data = await _c.from('messages').select()
        .eq('conversation_id', convId)
        .order('created_at', ascending: true);
    return (data as List).map((r) => Message.fromSupabase(r)).toList().cast<Message>();
  }

  Future<String> insertMessage(Message m) async {
    final map = m.toSupabase();
    await _c.from('messages').insert(map);
    return map['id'] as String;
  }

  /// Fork：拷贝源会话前 n 条消息到目标会话
  Future<void> copyMessagesBefore(String sourceConvId, String targetConvId, int count) async {
    final data = await _c.from('messages').select()
        .eq('conversation_id', sourceConvId)
        .order('created_at', ascending: true)
        .limit(count);
    for (final m in data as List) {
      final map = m as Map<String, dynamic>;
      final newId = _uuid.v4();
      await _c.from('messages').insert({
        'id': newId,
        'conversation_id': targetConvId,
        'role': map['role'],
        'content': map['content'],
        'created_at': map['created_at'],
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      });
    }
  }

  // ========== Memories ==========

  Future<List<Map<String, dynamic>>> getAllMemories() async {
    final data = await _c.from('memories').select().order('created_at', ascending: false);
    return (data as List).cast<Map<String, dynamic>>();
  }

  Future<String> insertMemory(String content, {String? sourceConvId}) async {
    final id = _uuid.v4();
    await _c.from('memories').insert({
      'id': id,
      'content': content,
      'source_conv_id': sourceConvId,
      'created_at': DateTime.now().millisecondsSinceEpoch,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    });
    return id;
  }

  Future<void> updateMemory(String id, String content) async {
    await _c.from('memories').update({
      'content': content,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    }).eq('id', id);
  }

  Future<void> deleteMemory(String id) async {
    await _c.from('memories').delete().eq('id', id);
  }

  Future<List<String>> getAllMemoryContents() async {
    final data = await _c.from('memories').select('content').order('created_at', ascending: false);
    return (data as List).map((r) => r['content'] as String).toList();
  }

  // ========== Tags ==========

  Future<List<Map<String, dynamic>>> getTags() async {
    final data = await _c.from('tags').select().order('name');
    return (data as List).cast<Map<String, dynamic>>();
  }

  Future<String> createTag(String name) async {
    final trimmed = name.trim();
    // Check existing
    final existing = await _c.from('tags').select('id').eq('name', trimmed).maybeSingle();
    if (existing != null) return existing['id'] as String;
    final id = _uuid.v4();
    final now = DateTime.now().millisecondsSinceEpoch;
    await _c.from('tags').insert({
      'id': id, 'name': trimmed,
      'created_at': now, 'updated_at': now,
    });
    return id;
  }

  Future<void> deleteTag(String id) async {
    await _c.from('tags').delete().eq('id', id);
  }

  Future<void> touchConversation(String id) async {
    await _c.from('conversations').update({
      'last_active_at': DateTime.now().millisecondsSinceEpoch,
    }).eq('id', id);
  }

  Future<void> markArchived(String id) async {
    await _c.from('conversations').update({
      'last_archived_at': DateTime.now().millisecondsSinceEpoch,
    }).eq('id', id);
  }

  Future<List<Map<String, dynamic>>> listAllConversations() async {
    final data = await _c.from('conversations').select('id, title, summary, user_note, created_at, last_active_at').order('last_active_at', ascending: false);
    return (data as List).cast<Map<String, dynamic>>();
  }

  // ========== Conversation Tags ==========

  Future<Map<String, List<String>>> getAllConversationTags() async {
    final data = await _c.from('conversation_tags').select('conversation_id, tags(name)');
    final map = <String, List<String>>{};
    for (final row in data as List) {
      final convId = row['conversation_id'] as String;
      final tagsObj = row['tags'] as Map<String, dynamic>?;
      final name = tagsObj?['name'] as String?;
      if (name != null) map.putIfAbsent(convId, () => []).add(name);
    }
    return map;
  }

  Future<List<String>> getTagsForConversation(String convId) async {
    final data = await _c.from('conversation_tags').select('tags(name)').eq('conversation_id', convId);
    final tags = <String>[];
    for (final row in data as List) {
      final tagsObj = row['tags'] as Map<String, dynamic>?;
      if (tagsObj != null) tags.add(tagsObj['name'] as String);
    }
    return tags;
  }

  Future<void> setConversationTags(String convId, List<String> tagIds) async {
    await _c.from('conversation_tags').delete().eq('conversation_id', convId);
    for (final tid in tagIds) {
      await _c.from('conversation_tags').insert({
        'conversation_id': convId,
        'tag_id': tid,
      });
    }
  }

  /// 按标签名设置会话标签（创建不存在的标签）
  Future<void> applyTags(String convId, List<String> tagNames) async {
    final tagIds = <String>[];
    for (final name in tagNames) {
      tagIds.add(await createTag(name));
    }
    await setConversationTags(convId, tagIds);
  }
}
