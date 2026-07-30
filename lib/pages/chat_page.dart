import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/conversation.dart';
import '../services/api_service.dart';
import '../services/voice/voice_controller.dart';
import '../widgets/voice_mic_button.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_math_fork/flutter_math.dart';

// ============ 与旧版完全一致的 LaTeX 渲染 ============

List<Widget> _buildContentWithLatex(String text, BuildContext context) {
  final regex = RegExp(r'\$\$(.+?)\$\$|\$(.+?)\$');
  final widgets = <Widget>[];
  int start = 0;

  for (final match in regex.allMatches(text)) {
    if (match.start > start) {
      widgets.add(MarkdownBody(
        data: text.substring(start, match.start),
        styleSheet: MarkdownStyleSheet(
          p: DefaultTextStyle.of(context).style,
          code: TextStyle(backgroundColor: Colors.grey.shade300, fontSize: 13, fontFamily: 'monospace'),
          codeblockDecoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(8)),
        ),
      ));
    }
    final isBlock = match.group(0)!.startsWith(r'$$');
    final tex = (isBlock ? match.group(1) : match.group(2)) ?? '';
    final formula = isBlock
        ? Center(child: Math.tex(tex, mathStyle: MathStyle.display, textStyle: const TextStyle(fontSize: 18)))
        : Math.tex(tex, mathStyle: MathStyle.text, textStyle: const TextStyle(fontSize: 16));
    widgets.add(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(tex, style: const TextStyle(fontSize: 0)),
      formula,
    ]));
    start = match.end;
  }

  if (start < text.length) {
    widgets.add(MarkdownBody(
      data: text.substring(start),
      styleSheet: MarkdownStyleSheet(
        p: DefaultTextStyle.of(context).style,
        code: TextStyle(backgroundColor: Colors.grey.shade300, fontSize: 13, fontFamily: 'monospace'),
        codeblockDecoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(8)),
      ),
    ));
  }

  return widgets.isEmpty ? [const Text('')] : widgets;
}

// ============ ChatPage ============

class ChatPage extends StatefulWidget {
  final String? conversationId;
  const ChatPage({super.key, this.conversationId});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  final _focusNode = FocusNode();
  final _api = ApiService();
  final List<Map<String, dynamic>> _messages = [];
  final Set<int> _expandedReasoning = {};
  String? _conversationId;
  String _convTitle = '新对话';
  String? _convSummary;
  String? _convNote;
  bool _isLoading = false;

  late final VoiceController _voiceController;

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    _voiceController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _voiceController = VoiceController();
    _voiceController.onVoiceSend = _sendVoiceText;
    // 模型懒加载：首次按麦克风时才初始化，打开会话不卡

    if (widget.conversationId != null) {
      _conversationId = widget.conversationId;
      _loadHistory();
    }
  }

  Future<void> _loadHistory() async {
    final messages = await _api.getMessages(_conversationId!);
    final conv = await _api.getConversation(_conversationId!);
    if (!mounted) return;
    setState(() {
      _convTitle = conv?.title ?? '新对话';
      _convSummary = conv?.summary;
      _convNote = conv?.userNote;
      _messages.addAll(messages.map((m) => {
        'role': m.role,
        'content': m.content,
        'reasoning': m.reasoning,
        'time': m.createdAt.millisecondsSinceEpoch,
      }));
    });
    _scrollToBottom();
  }

  // ============ 发送消息 — 全交给 VPS ============

  Future<void> _sendMessage() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    _controller.clear();
    _focusNode.requestFocus();
    await _sendTextAsMessage(text);
  }

  /// 语音回调用的接口，返回 AI 回复文本供 TTS 朗读
  Future<String> _sendVoiceText(String text) async {
    return await _sendTextAsMessage(text, voiceMode: true);
  }

  /// 核心发送逻辑，文字和语音共用
  Future<String> _sendTextAsMessage(String text, {bool voiceMode = false}) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    setState(() {
      _messages.add({'role': 'user', 'content': text, 'time': now});
      _isLoading = true;
    });

    try {
      final result = await _api.sendMessageSync(
        conversationId: _conversationId,
        content: text,
        voiceMode: voiceMode,
      );

      if (!mounted) return '';

      final serverMessages = (result['messages'] as List?) ?? [];
      _conversationId = result['conversation_id'] as String?;

      setState(() {
        _messages.clear();
        for (final m in serverMessages) {
          _messages.add({
            'role': m['role'],
            'content': m['content'],
            'reasoning': m['reasoning'],
            'time': m['created_at'],
          });
        }
        _isLoading = false;
      });

      _scrollToBottom();

      // 返回 AI 回复文本（语音模式需要朗读）
      final lastAssistant = serverMessages
          .where((m) => m['role'] == 'assistant')
          .toList();
      return lastAssistant.isNotEmpty
          ? (lastAssistant.last['content'] as String? ?? '')
          : '';
    } catch (e) {
      if (!mounted) return '出错了';
      setState(() {
        _messages.add({
          'role': 'assistant',
          'content': '出错了：$e',
          'time': DateTime.now().millisecondsSinceEpoch,
        });
        _isLoading = false;
      });
      return '出错了：$e';
    }
  }

  // ============ 编辑 / Fork ============

  Future<void> _editMessage(Map<String, dynamic> msg) async {
    final displayMsgs = _displayMessages;
    final editIndex = displayMsgs.indexOf(msg);
    if (editIndex < 0) return;

    final editController = TextEditingController(text: msg['content']);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('编辑消息'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('将创建新对话（Fork），原对话保留。',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
            const SizedBox(height: 8),
            TextField(
              controller: editController,
              maxLines: 5,
              autofocus: true,
              decoration: const InputDecoration(border: OutlineInputBorder()),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Fork 并发送')),
        ],
      ),
    );
    if (confirmed != true) return;

    final newText = editController.text.trim();
    if (newText.isEmpty) return;

    setState(() => _isLoading = true);

    final ancestorCount = editIndex;

    try {
      // VPS 端 Fork：创建新会话 + 拷贝前 ancestorCount 条消息
      final newConvId = await _api.forkConversation(
        _conversationId!,
        count: ancestorCount,
        title: newText,
      );

      // 切到新会话，追加祖先前消息
      setState(() {
        _conversationId = newConvId;
        _messages.clear();
        for (int i = 0; i < ancestorCount; i++) {
          _messages.add(displayMsgs[i]);
        }
      });

      // 发送编辑后的消息
      _controller.text = newText;
      await _sendMessage();

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
            TextField(controller: titleCtrl, decoration: const InputDecoration(labelText: '标题')),
            const SizedBox(height: 8),
            TextField(controller: summaryCtrl, decoration: const InputDecoration(labelText: '摘要'), maxLines: 3),
            const SizedBox(height: 8),
            TextField(controller: noteCtrl, decoration: const InputDecoration(labelText: '备注', hintText: '如：#重要 #待办')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(onPressed: () {
            setState(() {
              _convTitle = titleCtrl.text.trim().isEmpty ? _convTitle : titleCtrl.text.trim();
              _convSummary = summaryCtrl.text.trim().isEmpty ? null : summaryCtrl.text.trim();
              _convNote = noteCtrl.text.trim().isEmpty ? null : noteCtrl.text.trim();
            });
            if (_conversationId != null) {
              _api.getConversation(_conversationId!).then((c) {
                if (c != null) {
                  _api.updateConversation(Conversation(
                    uuid: c.uuid, title: _convTitle, summary: _convSummary,
                    userNote: _convNote, forkedFrom: c.forkedFrom,
                    createdAt: c.createdAt, lastActiveAt: c.lastActiveAt,
                    lastArchivedAt: c.lastArchivedAt,
                  ));
                }
              });
            }
            Navigator.pop(ctx);
          }, child: const Text('保存')),
        ],
      ),
    );
  }

  // ============ 归档 — 交给 VPS ============

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
              decoration: const InputDecoration(hintText: '有什么特别要求？（选填）', border: OutlineInputBorder()),
              maxLines: 2,
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(onPressed: () {
            instruction = instructionController.text.trim();
            Navigator.pop(ctx, true);
          }, child: const Text('归档')),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _isLoading = true);

    try {
      final result = await _api.archiveConversation(
        _conversationId!,
        instruction: instruction?.isNotEmpty == true ? instruction : null,
      );

      if (!mounted) return;
      setState(() => _isLoading = false);

      final title = result['title'] as String?;
      final segments = result['segments'] as int?;

      if (segments != null && segments > 1) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('已拆分为 $segments 条日记')),
          );
          Navigator.pop(context);
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('已归档：${title ?? _convTitle}')),
          );
        }
        if (title != null) setState(() => _convTitle = title);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('归档失败：$e')),
      );
    }
  }

  // ============ UI 辅助（与旧版一致）============

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients && _scrollController.position.maxScrollExtent > 0) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });
  }

  List<Map<String, dynamic>> get _displayMessages =>
      _messages.where((m) => m['content'] != null &&
          (m['role'] == 'user' || m['role'] == 'assistant')).toList();

  String _formatTime(int ms) {
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final msgDay = DateTime(dt.year, dt.month, dt.day);
    final hour = dt.hour.toString().padLeft(2, '0');
    final minute = dt.minute.toString().padLeft(2, '0');
    final timeStr = '$hour:$minute';
    if (msgDay == today) return timeStr;
    if (dt.year == now.year) return '${dt.month}月${dt.day}日 $timeStr';
    return '${dt.year}年${dt.month}月${dt.day}日 $timeStr';
  }

  // ============ Build（UI 结构完全不变）============

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_isLoading,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (!_isLoading) return;
        final navigator = Navigator.of(context);
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
        if (stay == true && mounted) navigator.pop();
      },
      child: Scaffold(
        resizeToAvoidBottomInset: true,
        appBar: AppBar(
          title: GestureDetector(
            onTap: _showEditDialog,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(child: Text(_convTitle, overflow: TextOverflow.ellipsis)),
                    const SizedBox(width: 4),
                    const Icon(Icons.edit, size: 14, color: Colors.white70),
                  ],
                ),
                if (_convSummary != null && _convSummary!.isNotEmpty)
                  Text(_convSummary!, style: const TextStyle(fontSize: 11, color: Colors.white70),
                      overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          actions: [
            if (_messages.length >= 2)
              IconButton(icon: const Icon(Icons.archive_outlined), tooltip: '归档', onPressed: _archive),
          ],
        ),
        body: Column(
          children: [
            Expanded(
              child: _messages.isEmpty
                  ? const Center(child: Text('开始对话吧'))
                  : ListView.builder(
                      controller: _scrollController,
                      itemCount: _displayMessages.length,
                      itemBuilder: (context, index) {
                        final msg = _displayMessages[index];
                        final isUser = msg['role'] == 'user';
                        final timeText = msg['time'] != null ? _formatTime(msg['time'] as int) : '';
                        final reasoning = msg['reasoning'] as String?;
                        final showReasoning = !isUser && reasoning != null && reasoning.isNotEmpty;

                        final bubble = Container(
                          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                          padding: const EdgeInsets.all(12),
                          constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.8),
                          decoration: BoxDecoration(
                            color: isUser ? Colors.teal.shade100 : Colors.grey.shade200,
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
                                        Row(mainAxisSize: MainAxisSize.min, children: [
                                          Icon(_expandedReasoning.contains(index)
                                              ? Icons.expand_less : Icons.expand_more,
                                              size: 16, color: Colors.orange.shade700),
                                          const SizedBox(width: 4),
                                          Text('思考过程', style: TextStyle(
                                              fontSize: 12, fontWeight: FontWeight.bold, color: Colors.orange.shade700)),
                                        ]),
                                        if (_expandedReasoning.contains(index)) ...[
                                          const SizedBox(height: 4),
                                          SelectableText(reasoning, style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
                                        ],
                                      ],
                                    ),
                                  ),
                                ),
                              SelectionArea(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: _buildContentWithLatex(msg['content']!, context),
                                ),
                              ),
                              if (timeText.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                                    Text(timeText, style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
                                    const SizedBox(width: 8),
                                    GestureDetector(
                                      onTap: () {
                                        Clipboard.setData(ClipboardData(text: msg['content']!));
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          const SnackBar(content: Text('已复制'), duration: Duration(seconds: 1)),
                                        );
                                      },
                                      child: Icon(Icons.copy, size: 13, color: Colors.grey.shade500),
                                    ),
                                  ]),
                                ),
                            ],
                          ),
                        );
                        return Align(
                          alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
                          child: isUser
                              ? GestureDetector(onLongPress: () => _editMessage(msg), child: bubble)
                              : bubble,
                        );
                      },
                    ),
            ),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 语音状态提示
                  ValueListenableBuilder<VoiceState>(
                    valueListenable: _voiceController.state,
                    builder: (context, state, _) {
                      if (state == VoiceState.idle) return const SizedBox.shrink();
                      if (state == VoiceState.loading) {
                        return Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          margin: const EdgeInsets.only(bottom: 4),
                          decoration: BoxDecoration(
                            color: Colors.blue.shade50,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text('正在加载语音模型...',
                            style: TextStyle(fontSize: 13, color: Colors.blue.shade700)),
                        );
                      }
                      return ValueListenableBuilder<String>(
                        valueListenable: _voiceController.partialText,
                        builder: (context, partial, _) {
                          return Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                            margin: const EdgeInsets.only(bottom: 4),
                            decoration: BoxDecoration(
                              color: state == VoiceState.listening
                                  ? Colors.red.shade50
                                  : state == VoiceState.processing
                                      ? Colors.orange.shade50
                                      : Colors.green.shade50,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              state == VoiceState.listening
                                  ? (partial.isNotEmpty ? '正在听: $partial' : '正在听...')
                                  : state == VoiceState.processing
                                      ? 'AI 正在思考...'
                                      : 'AI 正在回复...',
                              style: TextStyle(
                                fontSize: 13,
                                color: state == VoiceState.listening
                                    ? Colors.red.shade700
                                    : state == VoiceState.processing
                                        ? Colors.orange.shade700
                                        : Colors.green.shade700,
                              ),
                            ),
                          );
                        },
                      );
                    },
                  ),
                  // 输入行
                  Row(children: [
                    // 麦克风按钮
                    VoiceMicButton(controller: _voiceController),
                    Expanded(
                      child: CallbackShortcuts(
                        bindings: {
                          const SingleActivator(LogicalKeyboardKey.enter, control: true): () {
                            if (!_isLoading) _sendMessage();
                          },
                        },
                        child: TextField(
                          controller: _controller,
                          focusNode: _focusNode,
                          maxLines: 10,
                          minLines: 1,
                          textInputAction: TextInputAction.newline,
                          decoration: const InputDecoration(
                            hintText: '输入内容... (Enter换行, Ctrl+Enter发送)',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      onPressed: _isLoading ? null : _sendMessage,
                      icon: _isLoading
                          ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.send),
                    ),
                  ]),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
