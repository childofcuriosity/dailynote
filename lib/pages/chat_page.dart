import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import '../models/conversation.dart';
import '../models/message.dart';
import '../services/database.dart';
import '../services/ai_service.dart';
import '../services/secrets.dart';

// ============ 工具定义 ============

const _tools = [
  {
    'type': 'function',
    'function': {
      'name': 'list_history',
      'description': '列出所有历史对话的摘要索引（标题、日期、摘要、标签）。不用传关键词，调用后自己从返回的列表中判断哪些与当前话题相关。',
      'parameters': {'type': 'object', 'properties': {}},
    },
  },
  {
    'type': 'function',
    'function': {
      'name': 'load_conversation',
      'description': '载入指定对话的完整消息。仅当摘要不够、需要查看细节时调用。',
      'parameters': {
        'type': 'object',
        'properties': {
          'conversation_id': {'type': 'integer', 'description': '要载入的对话ID'},
        },
        'required': ['conversation_id'],
      },
    },
  },
  {
    'type': 'function',
    'function': {
      'name': 'list_memories',
      'description': '列出所有长期记忆。不用传关键词，调用后自己从返回的列表中判断哪些相关。',
      'parameters': {'type': 'object', 'properties': {}},
    },
  },
  {
    'type': 'function',
    'function': {
      'name': 'search_web',
      'description': '搜索互联网获取最新信息。',
      'parameters': {
        'type': 'object',
        'properties': {
          'query': {'type': 'string', 'description': '搜索词'},
        },
        'required': ['query'],
      },
    },
  },
  {
    'type': 'function',
    'function': {
      'name': 'create_memory',
      'description': '创建一条新的长期记忆。',
      'parameters': {
        'type': 'object',
        'properties': {
          'content': {'type': 'string', 'description': '记忆内容，一条原子事实'},
        },
        'required': ['content'],
      },
    },
  },
  {
    'type': 'function',
    'function': {
      'name': 'update_memory',
      'description': '修改一条已有的长期记忆。',
      'parameters': {
        'type': 'object',
        'properties': {
          'id': {'type': 'integer', 'description': '记忆ID（从 list_memories 获取）'},
          'content': {'type': 'string', 'description': '修改后的内容'},
        },
        'required': ['id', 'content'],
      },
    },
  },
  {
    'type': 'function',
    'function': {
      'name': 'delete_memory',
      'description': '删除一条长期记忆。',
      'parameters': {
        'type': 'object',
        'properties': {
          'id': {'type': 'integer', 'description': '记忆ID（从 list_memories 获取）'},
        },
        'required': ['id'],
      },
    },
  },
];

const _systemPrompt = '''你是一个贴心的日记助手，用中文回复，语气温暖像朋友聊天。

你可以使用以下工具：
- list_history: 获取所有历史对话的摘要索引，自己从中判断哪些相关
- load_conversation: 载入某段对话的完整内容（仅在摘要不够时用）
- list_memories: 获取所有长期记忆，自己从中判断哪些相关
- search_web: 搜索互联网获取最新信息

检索策略：
- 用户提到历史/之前/以前聊过 → 先调 list_history 获取所有对话摘要，自己筛选相关的
- 用户问关于他自己的事实/偏好 → 调 list_memories
- 摘要够用时不要调 load_conversation，节省上下文
- 不相关的对话/记忆忽略掉，不要引用
- create_memory / update_memory / delete_memory 用来管理记忆库
- 发现记忆中有旧信息、错误、重复时，主动用 update_memory 和 delete_memory 清理''';

// ============ ChatPage ============

class ChatPage extends StatefulWidget {
  final int? conversationId;
  const ChatPage({super.key, this.conversationId});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  final _focusNode = FocusNode();
  final _db = DatabaseService();
  final _ai = AiService(
    apiKey: Secrets.aiApiKey,
    baseUrl: Secrets.aiBaseUrl,
    model: Secrets.aiModel,
  );
  final List<Map<String, dynamic>> _messages = [];
  final Set<int> _expandedReasoning = {};
  int? _conversationId;
  String _convTitle = '新对话';
  String? _convSummary;
  String? _convNote;
  bool _isLoading = false;

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    if (widget.conversationId != null) {
      _conversationId = widget.conversationId;
      _loadHistory();
    }
  }

  Future<void> _loadHistory() async {
    final messages = await _db.getMessages(_conversationId!);
    final conv = await _db.getConversation(_conversationId!);
    setState(() {
      _convTitle = conv?.title ?? '新对话';
      _convSummary = conv?.summary;
      _convNote = conv?.userNote;
      _messages.addAll(
        messages.map((m) => {
              'role': m.role,
              'content': m.content,
              'time': m.createdAt.millisecondsSinceEpoch,
            }),
      );
    });
    // 只看不更新活跃时间，发消息时才更新
  }

  // ============ 发送消息 ============

  Future<void> _sendMessage() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    _controller.clear();
    _focusNode.requestFocus();

    final now = DateTime.now().millisecondsSinceEpoch;
    setState(() {
      _messages.add({'role': 'user', 'content': text, 'time': now});
    });

    if (_conversationId == null) {
      _convTitle = text.length > 20 ? '${text.substring(0, 20)}...' : text;
      final conv = Conversation(
        title: _convTitle,
        createdAt: DateTime.now(),
      );
      _conversationId = await _db.insertConversation(conv);
    }

    await _db.insertMessage(Message(
      conversationId: _conversationId,
      role: 'user',
      content: text,
      createdAt: DateTime.now(),
    ));

    await _db.touchConversation(_conversationId!);

    setState(() => _isLoading = true);

    try {
      final result = await _chatLoop();
      if (!mounted) return;
      final reply = result['content']!;
      final reasoning = result['reasoning'];
      final replyTime = DateTime.now().millisecondsSinceEpoch;
      setState(() {
        _messages.add({
          'role': 'assistant',
          'content': reply,
          'reasoning': reasoning,
          'time': replyTime,
        });
      });
      await _db.insertMessage(Message(
        conversationId: _conversationId,
        role: 'assistant',
        content: reply,
        createdAt: DateTime.now(),
      ));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _messages.add({
          'role': 'assistant',
          'content': '出错了：$e',
          'time': DateTime.now().millisecondsSinceEpoch,
        });
      });
    }

    if (!mounted) return;
    setState(() => _isLoading = false);
    _scrollToBottom();
  }

  /// function calling 循环，返回 {content, reasoning}
  Future<Map<String, String?>> _chatLoop() async {
    String? reasoning;
    final messages = _ai.buildMessages(
      systemPrompt: _systemPrompt,
      dateNote:
          '今天是 ${DateTime.now().year}年${DateTime.now().month}月${DateTime.now().day}日',
      conversation: List.from(_messages),
    );

    for (int loop = 0; loop < 5; loop++) {
      final response = await _ai.sendRequest(
        messages: messages,
        temperature: 0.7,
        tools: _tools,
      );

      if (!response.isToolCalls) {
        return {
          'content': response.content ?? '',
          'reasoning': response.reasoningContent,
        };
      }

      messages.add({
        'role': 'assistant',
        'tool_calls': response.toolCalls!
            .map((tc) => {
                  'id': tc.id,
                  'type': 'function',
                  'function': {
                    'name': tc.name,
                    'arguments': jsonEncode(tc.arguments),
                  },
                })
            .toList(),
      });

      for (final tc in response.toolCalls!) {
        final result = await _executeTool(tc.name, tc.arguments);
        messages.add({
          'role': 'tool',
          'tool_call_id': tc.id,
          'content': result,
        });
      }
    }
    return {'content': '（工具调用次数超限，请重新发送）', 'reasoning': reasoning};
  }

  Future<String> _executeTool(String name, Map<String, dynamic> args) async {
    switch (name) {
      case 'list_history':
        final results = await _db.listAllConversations();
        if (results.isEmpty) return '还没有任何历史对话。';
        final lines = <String>[];
        for (final r in results) {
          final date =
              DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int);
          final dateStr =
              '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
          final note =
              r['user_note'] != null ? ' [备注: ${r['user_note']}]' : '';
          final tags = await _db.getTagsForConversation(r['id'] as int);
          final tagStr = tags.isNotEmpty ? ' [${tags.join(', ')}]' : '';
          lines.add('ID:${r['id']} | $dateStr | ${r['title']}$tagStr$note\n  ${r['summary'] ?? '无摘要'}');
        }
        return lines.join('\n\n');

      case 'load_conversation':
        final msgs = await _db.getMessages(args['conversation_id'] as int);
        final conv =
            await _db.getConversation(args['conversation_id'] as int);
        final tags = conv != null ? await _db.getTagsForConversation(conv.id!) : <String>[];
        final header = conv != null
            ? '对话: ${conv.title}${tags.isNotEmpty ? ' [${tags.join(', ')}]' : ''}\n'
            : '';
        return header +
            msgs
                .map((m) =>
                    '[${m.role == 'user' ? '用户' : 'AI'}]: ${m.content}')
                .join('\n');

      case 'list_memories':
        final mems = await _db.getAllMemories();
        // debugPrint('list_memories 返回 ${mems.length} 条');
        if (mems.isEmpty) return '还没有任何长期记忆。';
        return mems
            .map((m) => '[ID:${m['id']}] ${m['content']}')
            .join('\n');

      case 'search_web':
        return await _searchWeb(args['query'] as String);

      case 'create_memory':
        final cid = await _db.insertMemory(args['content'] as String);
        return '已创建记忆 ID:$cid';

      case 'update_memory':
        await _db.updateMemory(args['id'] as int, args['content'] as String);
        return '已更新记忆 ID:${args['id']}';

      case 'delete_memory':
        await _db.deleteMemory(args['id'] as int);
        return '已删除记忆 ID:${args['id']}';

      default:
        return '未知工具: $name';
    }
  }

  Future<String> _searchWeb(String query) async {
    final response = await http.post(
      Uri.parse('https://google.serper.dev/search'),
      headers: {
        'X-API-KEY': 'f5906a5321623f7d082d5a2eb7a20a07291cba69',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({'q': query, 'gl': 'cn', 'hl': 'zh-cn'}),
    );
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      final organic = data['organic'] as List<dynamic>?;
      if (organic == null || organic.isEmpty) return '未找到搜索结果。';
      return organic.take(5).map((r) {
        final title = r['title'] as String? ?? '';
        final snippet = r['snippet'] as String? ?? '';
        final link = r['link'] as String? ?? '';
        return '$title\n  $snippet\n  $link';
      }).join('\n\n');
    } else {
      return '搜索失败 (${response.statusCode})';
    }
  }

  // ============ 编辑 / Fork ============

  Future<void> _editMessage(Map<String, dynamic> msg) async {
    // 找到被编辑消息在 _displayMessages 中的索引
    final displayMsgs = _displayMessages;
    final editIndex = displayMsgs.indexOf(msg);
    if (editIndex < 0) return;

    // 祖先消息数量 = 被编辑消息之前的消息数
    final ancestorCount = editIndex;

    final editController = TextEditingController(text: msg['content']);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('编辑消息'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('将创建一条新对话（Fork），前 $ancestorCount 条消息会被复制过去。',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
            const SizedBox(height: 8),
            TextField(
              controller: editController,
              maxLines: 5,
              autofocus: true,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Fork 并发送'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final newText = editController.text.trim();
    if (newText.isEmpty) return;

    setState(() => _isLoading = true);

    try {
      // 创建新会话
      final newConvId = await _db.insertConversation(Conversation(
        title: newText.length > 20
            ? '${newText.substring(0, 20)}...'
            : newText,
        forkedFrom: _conversationId,
        createdAt: DateTime.now(),
      ));

      // 拷贝祖先消息
      if (ancestorCount > 0) {
        await _db.copyMessagesBefore(
            _conversationId!, newConvId, ancestorCount);
      }

      // 切到新会话
      setState(() {
        _conversationId = newConvId;
        _messages.clear();
        // 重建祖先消息列表
        for (int i = 0; i < ancestorCount; i++) {
          _messages.add(displayMsgs[i]);
        }
      });

      // 用编辑后的文本发送
      _controller.text = newText;
      await _sendMessage();

      // 自动归档原会话
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已创建新分支（Fork），原对话保留')),
        );
      }
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Fork 失败：$e')),
        );
      }
    }
  }

  Future<void> _applyTags(int convId, List<String> tagNames) async {
    final tagIds = <int>[];
    for (final name in tagNames) {
      final tid = await _db.createTag(name);
      tagIds.add(tid);
    }
    await _db.setConversationTags(convId, tagIds);
  }

  // ============ 编辑元数据 ============

  Future<void> _showEditDialog() async {
    final titleCtrl = TextEditingController(text: _convTitle);
    final summaryCtrl = TextEditingController(text: _convSummary ?? '');
    final noteCtrl = TextEditingController(text: _convNote ?? '');

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('编辑'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: titleCtrl,
              decoration: const InputDecoration(labelText: '标题'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: summaryCtrl,
              decoration: const InputDecoration(labelText: '摘要'),
              maxLines: 3,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: noteCtrl,
              decoration: const InputDecoration(
                  labelText: '备注', hintText: '如：#重要 #待办'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              setState(() {
                _convTitle = titleCtrl.text.trim().isEmpty
                    ? _convTitle
                    : titleCtrl.text.trim();
                _convSummary = summaryCtrl.text.trim().isEmpty
                    ? null
                    : summaryCtrl.text.trim();
                _convNote = noteCtrl.text.trim().isEmpty
                    ? null
                    : noteCtrl.text.trim();
              });
              if (_conversationId != null) {
                _db.getConversation(_conversationId!).then((c) {
                  if (c != null) {
                    _db.updateConversation(Conversation(
                      id: c.id,
                      title: _convTitle,
                      summary: _convSummary,
                      userNote: _convNote,
                      forkedFrom: c.forkedFrom,
                      createdAt: c.createdAt,
                      lastActiveAt: c.lastActiveAt,
                      lastArchivedAt: c.lastArchivedAt,
                    ));
                  }
                });
              }
              Navigator.pop(ctx);
                      },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  // ============ 归档 ============

  Future<void> _archive() async {
    final instructionController = TextEditingController();
    String? instruction;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('归档这段对话'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('AI 将自动生成标题、摘要并提取记忆'),
            const SizedBox(height: 8),
            TextField(
              controller: instructionController,
              decoration: const InputDecoration(
                hintText: '有什么特别要求？（选填）',
                border: OutlineInputBorder(),
              ),
              maxLines: 2,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              instruction = instructionController.text.trim();
              Navigator.pop(ctx, true);
            },
            child: const Text('归档'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _isLoading = true);

    try {
      // 获取已有记忆传给 AI，避免重复输出
      final existingMemories = (await _db.getAllMemories())
          .map((m) => m['content'] as String)
          .toList();

      final archiveResult = await _ai.archiveConversation(
        messages: _messages,
        userInstruction:
            instruction != null && instruction!.isNotEmpty ? instruction : null,
        existingMemories: existingMemories,
        tagLibrary: (await _db.getTags()).map((t) => t['name'] as String).toList(),
      );

      // 调试：打印 AI 返回的完整结果
      // debugPrint('归档结果: ${jsonEncode(archiveResult)}');

      final segments = (archiveResult['segments'] as List<dynamic>?) ?? [];
      if (segments.isEmpty) throw Exception('归档返回为空');

      if (segments.length == 1) {
        final seg = segments[0] as Map<String, dynamic>;
        final current = await _db.getConversation(_conversationId!);
        if (current != null) {
          final newTitle = seg['title'] as String? ?? current.title;
          final newSummary = seg['summary'] as String? ?? current.summary;
          setState(() {
            _convTitle = newTitle;
            _convSummary = newSummary;
          });
          await _db.updateConversation(Conversation(
            id: current.id,
            title: newTitle,
            summary: newSummary,
            userNote: current.userNote,
            forkedFrom: current.forkedFrom,
            createdAt: current.createdAt,
            lastActiveAt: current.lastActiveAt,
            lastArchivedAt: DateTime.now(),
          ));
          // 标签
          final tags = (seg['tags'] as List<dynamic>?)
                  ?.map((t) => t.toString())
                  .toList() ??
              [];
          await _applyTags(_conversationId!, tags);
        }
        await _saveMemories(seg['memories'] as List<dynamic>?,
            _conversationId!);
        await _db.markArchived(_conversationId!);

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('已归档：${seg['title']}')),
          );
        }
      } else {
        for (final s in segments) {
          final seg = s as Map<String, dynamic>;
          final startIndex = seg['startIndex'] as int? ?? 0;
          final endIndex =
              seg['endIndex'] as int? ?? _messages.length - 1;

          final newConvId = await _db.insertConversation(Conversation(
            title: seg['title'] as String? ?? '未命名',
            summary: seg['summary'] as String?,
            forkedFrom: _conversationId,
            createdAt: DateTime.now(),
            lastArchivedAt: DateTime.now(),
          ));

          // 标签
          final segTags = (seg['tags'] as List<dynamic>?)
                  ?.map((t) => t.toString())
                  .toList() ??
              [];
          await _applyTags(newConvId, segTags);

          for (int i = startIndex;
              i <= endIndex && i < _messages.length;
              i++) {
            final m = _messages[i];
            if (m['content'] != null &&
                (m['role'] == 'user' || m['role'] == 'assistant')) {
              await _db.insertMessage(Message(
                conversationId: newConvId,
                role: m['role'] as String,
                content: m['content'] as String,
                createdAt: m['time'] != null
                    ? DateTime.fromMillisecondsSinceEpoch(m['time'] as int)
                    : DateTime.now(),
              ));
            }
          }

          await _saveMemories(
              seg['memories'] as List<dynamic>?, newConvId);
        }

        if (_conversationId != null) {
          await _db.deleteConversation(_conversationId!);
        }

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('已拆分为 ${segments.length} 条日记')),
          );
                Navigator.pop(context);
          return;
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('归档失败：$e')),
        );
      }
    }

    setState(() => _isLoading = false);
  }

  Future<void> _saveMemories(List<dynamic>? memories, int convId) async {
    // debugPrint('_saveMemories 收到: $memories');
    if (memories == null) return;
    for (final m in memories) {
      if (m is String && m.trim().isNotEmpty) {
        final id = await _db.insertMemory(m.trim(), sourceConvId: convId);
        // debugPrint('插入记忆 id=$id: ${m.trim()}');
      }
    }
  }

  // ============ UI 辅助 ============

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  List<Map<String, dynamic>> get _displayMessages =>
      _messages
          .where((m) =>
              m['content'] != null &&
              (m['role'] == 'user' || m['role'] == 'assistant'))
          .toList();

  String _formatTime(int ms) {
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final msgDay = DateTime(dt.year, dt.month, dt.day);
    final hour = dt.hour.toString().padLeft(2, '0');
    final minute = dt.minute.toString().padLeft(2, '0');
    final timeStr = '$hour:$minute';
    if (msgDay == today) return timeStr;
    if (dt.year == now.year) {
      return '${dt.month}月${dt.day}日 $timeStr';
    }
    return '${dt.year}年${dt.month}月${dt.day}日 $timeStr';
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_isLoading,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (!_isLoading) return;
        final stay = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('AI 正在回复'),
            content: const Text('离开会丢失本次回复，确定要离开吗？'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('留下')),
              TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('离开')),
            ],
          ),
        );
        if (stay == true && mounted) {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: GestureDetector(
          onTap: _showEditDialog,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(child: Text(_convTitle, overflow: TextOverflow.ellipsis)),
              const SizedBox(width: 4),
              const Icon(Icons.edit, size: 14, color: Colors.white70),
            ],
          ),
        ),
        actions: [
          if (_messages.length >= 2)
            IconButton(
              icon: const Icon(Icons.archive_outlined),
              tooltip: '归档',
              onPressed: _archive,
            ),
        ],
      ),
      body: Column(
        children: [
          // 摘要区
          if (_convSummary != null && _convSummary!.isNotEmpty)
            GestureDetector(
              onTap: _showEditDialog,
              child: Container(
                width: double.infinity,
                margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.blue.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.blue.shade100),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.summarize, size: 16, color: Colors.blue.shade400),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _convSummary!,
                        style: TextStyle(fontSize: 13, color: Colors.grey.shade700),
                      ),
                    ),
                    Icon(Icons.edit, size: 14, color: Colors.grey.shade400),
                  ],
                ),
              ),
            ),
          Expanded(
            child: _messages.isEmpty
                ? const Center(child: Text('开始对话吧'))
                : ListView.builder(
                    controller: _scrollController,
                    itemCount: _displayMessages.length,
                    itemBuilder: (context, index) {
                      final msg = _displayMessages[index];
                      final isUser = msg['role'] == 'user';
                      final timeText = msg['time'] != null
                          ? _formatTime(msg['time'] as int)
                          : '';
                      final reasoning = msg['reasoning'] as String?;
                      final showReasoning =
                          !isUser && reasoning != null && reasoning.isNotEmpty;

                      final bubble = Container(
                        margin: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 4),
                        padding: const EdgeInsets.all(12),
                        constraints: BoxConstraints(
                          maxWidth:
                              MediaQuery.of(context).size.width * 0.8,
                        ),
                        decoration: BoxDecoration(
                          color: isUser
                              ? Colors.teal.shade100
                              : Colors.grey.shade200,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (showReasoning)
                              GestureDetector(
                                onTap: () {
                                  setState(() {
                                    if (_expandedReasoning.contains(index)) {
                                      _expandedReasoning.remove(index);
                                    } else {
                                      _expandedReasoning.add(index);
                                    }
                                  });
                                },
                                child: Container(
                                  margin: const EdgeInsets.only(bottom: 8),
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                    color: Colors.yellow.shade50,
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(color: Colors.yellow.shade200),
                                  ),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(
                                            _expandedReasoning.contains(index)
                                                ? Icons.expand_less
                                                : Icons.expand_more,
                                            size: 16,
                                            color: Colors.orange.shade700,
                                          ),
                                          const SizedBox(width: 4),
                                          Text(
                                            '思考过程',
                                            style: TextStyle(
                                              fontSize: 12,
                                              fontWeight: FontWeight.bold,
                                              color: Colors.orange.shade700,
                                            ),
                                          ),
                                        ],
                                      ),
                                      if (_expandedReasoning.contains(index)) ...[
                                        const SizedBox(height: 4),
                                        Text(
                                          reasoning,
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: Colors.grey.shade700,
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                              ),
                            SelectableText(msg['content']!),
                            if (timeText.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Text(
                                  timeText,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: Colors.grey.shade600,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      );
                      return Align(
                        alignment: isUser
                            ? Alignment.centerRight
                            : Alignment.centerLeft,
                        child: isUser
                            ? GestureDetector(
                                onLongPress: () => _editMessage(msg),
                                child: bubble,
                              )
                            : bubble,
                      );
                    },
                  ),
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    focusNode: _focusNode,
                    decoration: const InputDecoration(
                      hintText: '输入内容...',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted:
                        _isLoading ? null : (_) => _sendMessage(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  onPressed: _isLoading ? null : _sendMessage,
                  icon: _isLoading
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child:
                              CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.send),
                ),
              ],
            ),
          ),
        ],
      ),
      ),
    );
  }
}
