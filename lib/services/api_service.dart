import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/conversation.dart';
import '../models/message.dart';
import 'api_config.dart';

/// VPS API 客户端 — 对标 SupaService 的全部方法签名
class ApiService {
  final String _base;

  ApiService({String? baseUrl}) : _base = baseUrl ?? ApiConfig.baseUrl;

  Map<String, String> get _headers => {'Content-Type': 'application/json'};

  // ========== Conversations ==========

  Future<List<Conversation>> getConversations({List<String>? tagIds}) async {
    final resp = await http.get(Uri.parse('$_base/conversations'), headers: _headers);
    _check(resp);
    final list = jsonDecode(resp.body) as List;
    return list.map((r) => Conversation.fromSupabase(r)).toList();
  }

  Future<Conversation?> getConversation(String id) async {
    final resp = await http.get(Uri.parse('$_base/conversations/$id'), headers: _headers);
    if (resp.statusCode == 404) return null;
    _check(resp);
    return Conversation.fromSupabase(jsonDecode(resp.body));
  }

  Future<String> insertConversation(Conversation c) async {
    final resp = await http.post(
      Uri.parse('$_base/conversations'),
      headers: _headers,
      body: jsonEncode({'title': c.title}),
    );
    _check(resp);
    final data = jsonDecode(resp.body);
    return data['id'] as String;
  }

  Future<void> updateConversation(Conversation c) async {
    final resp = await http.put(
      Uri.parse('$_base/conversations/${c.uuid}'),
      headers: _headers,
      body: jsonEncode(c.toSupabase()),
    );
    _check(resp);
  }

  Future<void> deleteConversation(String id) async {
    final resp = await http.delete(Uri.parse('$_base/conversations/$id'), headers: _headers);
    _check(resp);
  }

  Future<int> getConversationsCount() async {
    return (await getConversations()).length;
  }

  // ========== Messages ==========

  Future<List<Message>> getMessages(String convId) async {
    final resp = await http.get(
      Uri.parse('$_base/conversations/$convId/messages'),
      headers: _headers,
    );
    _check(resp);
    final list = jsonDecode(resp.body) as List;
    return list.map((r) => Message.fromSupabase(r)).toList();
  }

  Future<String> insertMessage(Message m) async {
    // 通常用 sendMessage 代替，但保留接口兼容
    final resp = await http.post(
      Uri.parse('$_base/messages'),
      headers: _headers,
      body: jsonEncode({
        'conversation_id': m.conversationId,
        'content': m.content,
      }),
    );
    _check(resp);
    final data = jsonDecode(resp.body);
    return data['id'] ?? '';
  }

  /// 发送消息并同步等待 AI 回复 — 这是 Flutter App 的主要发送方式
  Future<Map<String, dynamic>> sendMessageSync({
    String? conversationId,
    required String content,
  }) async {
    final resp = await http.post(
      Uri.parse('$_base/messages?wait=true'),
      headers: _headers,
      body: jsonEncode({
        'conversation_id': conversationId ?? '',
        'content': content,
      }),
    );
    _check(resp);
    return jsonDecode(resp.body);
  }

  /// Fork：VPS 端创建新会话 + 拷贝前 count 条消息，返回新会话 ID
  Future<String> forkConversation(String sourceConvId, {int count = 0, String title = 'Fork'}) async {
    final resp = await http.post(
      Uri.parse('$_base/conversations/$sourceConvId/fork'),
      headers: _headers,
      body: jsonEncode({'count': count, 'title': title}),
    );
    _check(resp);
    return jsonDecode(resp.body)['id'] as String;
  }

  // ========== Memories ==========

  Future<List<Map<String, dynamic>>> getAllMemories() async {
    final resp = await http.get(Uri.parse('$_base/memories'), headers: _headers);
    _check(resp);
    return (jsonDecode(resp.body) as List).cast<Map<String, dynamic>>();
  }

  Future<String> insertMemory(String content,
      {String? sourceConvId, String? name, String? description, String? type}) async {
    final resp = await http.post(
      Uri.parse('$_base/memories'),
      headers: _headers,
      body: jsonEncode({
        'content': content,
        'source_conv_id': sourceConvId,
        if (name != null) 'name': name,
        if (description != null) 'description': description,
        if (type != null) 'type': type,
      }),
    );
    _check(resp);
    final data = jsonDecode(resp.body);
    return data['id'] as String;
  }

  Future<void> updateMemory(String id, String content,
      {String? name, String? description, String? type}) async {
    final body = <String, dynamic>{'content': content};
    if (name != null) body['name'] = name;
    if (description != null) body['description'] = description;
    if (type != null) body['type'] = type;
    final resp = await http.put(
      Uri.parse('$_base/memories/$id'),
      headers: _headers,
      body: jsonEncode(body),
    );
    _check(resp);
  }

  Future<void> deleteMemory(String id) async {
    final resp = await http.delete(Uri.parse('$_base/memories/$id'), headers: _headers);
    _check(resp);
  }

  Future<List<String>> getAllMemoryContents() async {
    final mems = await getAllMemories();
    return mems.map((m) => m['content'] as String).toList();
  }

  // ========== Tags ==========

  Future<List<Map<String, dynamic>>> getTags() async {
    final resp = await http.get(Uri.parse('$_base/tags'), headers: _headers);
    _check(resp);
    return (jsonDecode(resp.body) as List).cast<Map<String, dynamic>>();
  }

  Future<String> createTag(String name) async {
    final resp = await http.post(
      Uri.parse('$_base/tags'),
      headers: _headers,
      body: jsonEncode({'name': name}),
    );
    _check(resp);
    return jsonDecode(resp.body)['id'] as String;
  }

  Future<void> deleteTag(String id) async {
    final resp = await http.delete(Uri.parse('$_base/tags/$id'), headers: _headers);
    _check(resp);
  }

  Future<void> markArchived(String id) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await http.put(
      Uri.parse('$_base/conversations/$id'),
      headers: _headers,
      body: jsonEncode({'last_archived_at': now}),
    );
  }

  Future<List<Map<String, dynamic>>> listAllConversations() async {
    final convs = await getConversations();
    final result = <Map<String, dynamic>>[];
    for (final c in convs) {
      result.add({
        'id': c.uuid,
        'title': c.title,
        'summary': c.summary,
        'user_note': c.userNote,
        'created_at': c.createdAt.millisecondsSinceEpoch,
        'last_active_at': c.lastActiveAt.millisecondsSinceEpoch,
      });
    }
    return result;
  }

  // ========== Conversation Tags ==========

  Future<Map<String, List<String>>> getAllConversationTags() async {
    // VPS API 的 /conversations 已在每条记录返回 tags
    final resp = await http.get(Uri.parse('$_base/conversations'), headers: _headers);
    _check(resp);
    final list = jsonDecode(resp.body) as List;
    final result = <String, List<String>>{};
    for (final item in list) {
      final rawTags = item['tags'] as List<dynamic>? ?? [];
      result[item['id'] as String] = rawTags.cast<String>();
    }
    return result;
  }

  Future<void> setConversationTags(String convId, List<String> tagIds) async {
    await http.post(
      Uri.parse('$_base/conversations/$convId/tags'),
      headers: _headers,
      body: jsonEncode({'tags': tagIds}),
    );
  }

  /// 按标签名设置会话标签
  Future<void> applyTags(String convId, List<String> tagNames) async {
    await setConversationTags(convId, tagNames);
  }

  // ========== Archive ==========

  /// 归档会话（VPS 端处理）
  Future<Map<String, dynamic>> archiveConversation(
    String convId, {
    String? instruction,
  }) async {
    final resp = await http.post(
      Uri.parse('$_base/conversations/$convId/archive'),
      headers: _headers,
      body: jsonEncode({'instruction': instruction ?? ''}),
    );
    _check(resp);
    return jsonDecode(resp.body);
  }

  // ========== Soul ==========

  Future<String> getSoul() async {
    final resp = await http.get(Uri.parse('$_base/soul'), headers: _headers);
    _check(resp);
    return jsonDecode(resp.body)['content'] as String;
  }

  Future<void> updateSoul(String content) async {
    final resp = await http.put(
      Uri.parse('$_base/soul'),
      headers: _headers,
      body: jsonEncode({'content': content}),
    );
    _check(resp);
  }

  // ========== internal ==========

  void _check(http.Response resp) {
    if (resp.statusCode >= 400) {
      throw Exception('API error ${resp.statusCode}: ${resp.body}');
    }
  }
}
