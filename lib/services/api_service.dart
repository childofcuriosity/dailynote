import 'l10n.dart';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/conversation.dart';
import '../models/message.dart';
import 'api_config.dart';

/// VPS API client — mirrors all method signatures of SupaService
class ApiService {
  static final sessionToken = ValueNotifier<String?>(null);
  static String? account;

  Future<void> login(String selectedAccount, String password) async {
    final resp = await http
        .post(
          Uri.parse('$_base/session'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'account': selectedAccount, 'password': password}),
        )
        .timeout(const Duration(seconds: 20));
    if (resp.statusCode != 200) {
      try {
        final body = jsonDecode(resp.body) as Map<String, dynamic>;
        throw StateError(body['error'] as String? ?? tr("Sign-in failed"));
      } on FormatException {
        throw StateError(tr("Unable to connect. Please try again later."));
      }
    }
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    account = body['account'] as String;
    AppLanguage.isChinese = account == 'personal';
    sessionToken.value = body['token'] as String;
  }

  Future<void> logout() async {
    final headers = _headers;
    account = null;
    AppLanguage.isChinese = false;
    sessionToken.value = null;
    try {
      await http
          .delete(Uri.parse('$_base/session'), headers: headers)
          .timeout(const Duration(seconds: 10));
    } catch (_) {
      // Local view cleared; the server session will still expire automatically.
    }
  }

  final String _base;
  // An old page must never send requests under a newly selected account.
  final String? _requestToken;

  ApiService({String? baseUrl})
    : _base = baseUrl ?? ApiConfig.baseUrl,
      _requestToken = sessionToken.value;

  Map<String, String> get _headers => {
    'Content-Type': 'application/json',
    if (_requestToken != null) 'Authorization': 'Bearer $_requestToken',
  };

  // ========== Conversations ==========

  Future<List<Conversation>> getConversations({List<String>? tagIds}) async {
    final resp = await http.get(
      Uri.parse('$_base/conversations'),
      headers: _headers,
    );
    _check(resp);
    final list = jsonDecode(resp.body) as List;
    return list.map((r) => Conversation.fromSupabase(r)).toList();
  }

  Future<Conversation?> getConversation(String id) async {
    final resp = await http.get(
      Uri.parse('$_base/conversations/$id'),
      headers: _headers,
    );
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
    final resp = await http.delete(
      Uri.parse('$_base/conversations/$id'),
      headers: _headers,
    );
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
    // Usually use sendMessage instead, but keep the interface for compatibility
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

  /// Send a message and synchronously wait for the AI reply — this is the main send method for the Flutter app
  Future<Map<String, dynamic>> sendMessageSync({
    String? conversationId,
    required String content,
    bool voiceMode = false,
  }) async {
    final body = <String, dynamic>{
      'conversation_id': conversationId ?? '',
      'content': content,
    };
    if (voiceMode) body['voice'] = true;

    final resp = await http.post(
      Uri.parse('$_base/messages?wait=true'),
      headers: _headers,
      body: jsonEncode(body),
    );
    _check(resp);
    return jsonDecode(resp.body);
  }

  /// Fork: creates a new conversation on the VPS side + copies the first count messages, returns new conversation ID
  Future<String> forkConversation(
    String sourceConvId, {
    int count = 0,
    String title = 'Fork',
  }) async {
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
    final resp = await http.get(
      Uri.parse('$_base/memories'),
      headers: _headers,
    );
    _check(resp);
    return (jsonDecode(resp.body) as List).cast<Map<String, dynamic>>();
  }

  Future<String> insertMemory(
    String content, {
    String? sourceConvId,
    String? name,
    String? description,
    String? type,
  }) async {
    final resp = await http.post(
      Uri.parse('$_base/memories'),
      headers: _headers,
      body: jsonEncode({
        'content': content,
        'source_conv_id': sourceConvId,
        'name': ?name,
        'description': ?description,
        'type': ?type,
      }),
    );
    _check(resp);
    final data = jsonDecode(resp.body);
    return data['id'] as String;
  }

  Future<void> updateMemory(
    String id,
    String content, {
    String? name,
    String? description,
    String? type,
  }) async {
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
    final resp = await http.delete(
      Uri.parse('$_base/memories/$id'),
      headers: _headers,
    );
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
    final resp = await http.delete(
      Uri.parse('$_base/tags/$id'),
      headers: _headers,
    );
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
    // The VPS API /conversations already returns tags on each record
    final resp = await http.get(
      Uri.parse('$_base/conversations'),
      headers: _headers,
    );
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

  /// Set conversation tags by tag name
  Future<void> applyTags(String convId, List<String> tagNames) async {
    await setConversationTags(convId, tagNames);
  }

  // ========== Archive ==========

  /// Archive session (handled on VPS side)
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
    if (resp.statusCode == 401 && sessionToken.value == _requestToken) {
      account = null;
      AppLanguage.isChinese = false;
      sessionToken.value = null;
    }
    if (resp.statusCode >= 400) {
      throw Exception('API error ${resp.statusCode}: ${resp.body}');
    }
  }
}
