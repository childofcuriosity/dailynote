import '../services/l10n.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import '../models/conversation.dart';
import '../services/api_service.dart';
// import '../services/voice/voice_controller.dart';
// import '../widgets/voice_mic_button.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_math_fork/flutter_math.dart';

// ============ LaTeX rendering exactly the same as the old version ============

List<Widget> _buildContentWithLatex(String text, BuildContext context) {
  final regex = RegExp(r'\$\$(.+?)\$\$|\$(.+?)\$');
  final widgets = <Widget>[];
  int start = 0;

  for (final match in regex.allMatches(text)) {
    if (match.start > start) {
      widgets.add(
        MarkdownBody(
          data: text.substring(start, match.start),
          styleSheet: MarkdownStyleSheet(
            p: DefaultTextStyle.of(context).style,
            code: TextStyle(
              backgroundColor: Colors.grey.shade300,
              fontSize: 13,
              fontFamily: 'monospace',
            ),
            codeblockDecoration: BoxDecoration(
              color: Colors.grey.shade300,
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),
      );
    }
    final isBlock = match.group(0)!.startsWith(r'$$');
    final tex = (isBlock ? match.group(1) : match.group(2)) ?? '';
    final formula = isBlock
        ? Center(
            child: Math.tex(
              tex,
              mathStyle: MathStyle.display,
              textStyle: TextStyle(fontSize: 18),
            ),
          )
        : Math.tex(
            tex,
            mathStyle: MathStyle.text,
            textStyle: TextStyle(fontSize: 16),
          );
    widgets.add(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(tex, style: TextStyle(fontSize: 0)),
          formula,
        ],
      ),
    );
    start = match.end;
  }

  if (start < text.length) {
    widgets.add(
      MarkdownBody(
        data: text.substring(start),
        styleSheet: MarkdownStyleSheet(
          p: DefaultTextStyle.of(context).style,
          code: TextStyle(
            backgroundColor: Colors.grey.shade300,
            fontSize: 13,
            fontFamily: 'monospace',
          ),
          codeblockDecoration: BoxDecoration(
            color: Colors.grey.shade300,
            borderRadius: BorderRadius.circular(8),
          ),
        ),
      ),
    );
  }

  return widgets.isEmpty ? [Text('')] : widgets;
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
  String _convTitle = tr("New conversation");
  String? _convSummary;
  String? _convNote;
  bool _isLoading = false;

  // late final VoiceController _voiceController;

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    // _voiceController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    // _voiceController = VoiceController();
    // _voiceController.onVoiceSend = _sendVoiceText;
    // Lazy-load models: initialize only when the microphone is first pressed, so opening a session won't lag

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
      _convTitle = conv?.title ?? tr("New conversation");
      _convSummary = conv?.summary;
      _convNote = conv?.userNote;
      _messages.addAll(
        messages.map(
          (m) => {
            'role': m.role,
            'content': m.content,
            'reasoning': m.reasoning,
            'time': m.createdAt.millisecondsSinceEpoch,
          },
        ),
      );
    });
    _scrollToBottom();
  }

  // ============ Send message — all handled by VPS ============

  Future<void> _sendMessage() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    _controller.clear();
    _focusNode.requestFocus();
    await _sendTextAsMessage(text);
  }

  /// Interface for voice callback: returns AI reply text for TTS to read aloud
  /* Voice disabled.
  Future<String> _sendVoiceText(String text) async {
    return await _sendTextAsMessage(text, voiceMode: true);
  }
  */

  /// Core sending logic, shared by text and voice
  Future<String> _sendTextAsMessage(
    String text, {
    bool voiceMode = false,
  }) async {
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

      // Returns AI reply text (voice mode needs to read it aloud)
      final lastAssistant = serverMessages
          .where((m) => m['role'] == 'assistant')
          .toList();
      return lastAssistant.isNotEmpty
          ? (lastAssistant.last['content'] as String? ?? '')
          : '';
    } catch (e) {
      if (!mounted) return tr("Something went wrong");
      setState(() {
        _messages.add({
          'role': 'assistant',
          'content': tr("Error: {0}", [e]),
          'time': DateTime.now().millisecondsSinceEpoch,
        });
        _isLoading = false;
      });
      return tr("Error: {0}", [e]);
    }
  }

  // ============ Edit / Fork ============

  Future<void> _editMessage(Map<String, dynamic> msg) async {
    final displayMsgs = _displayMessages;
    final editIndex = displayMsgs.indexOf(msg);
    if (editIndex < 0) return;

    final editController = TextEditingController(text: msg['content']);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr("Edit message")),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              tr(
                "This creates a new conversation branch and keeps the original.",
              ),
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
            SizedBox(height: 8),
            TextField(
              controller: editController,
              maxLines: 5,
              autofocus: true,
              decoration: InputDecoration(border: OutlineInputBorder()),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr("Cancel")),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr("Branch and send")),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final newText = editController.text.trim();
    if (newText.isEmpty) return;

    setState(() => _isLoading = true);

    final ancestorCount = editIndex;

    try {
      // VPS-side fork: create a new session + copy the previous ancestorCount messages
      final newConvId = await _api.forkConversation(
        _conversationId!,
        count: ancestorCount,
        title: newText,
      );

      // Switch to the new session and append the messages before the ancestor
      setState(() {
        _conversationId = newConvId;
        _messages.clear();
        for (int i = 0; i < ancestorCount; i++) {
          _messages.add(displayMsgs[i]);
        }
      });

      // Send the edited message
      _controller.text = newText;
      await _sendMessage();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              tr("New branch created. The original conversation is preserved."),
            ),
          ),
        );
      }
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr("Could not create branch: {0}", [e]))),
        );
      }
    }
  }

  // ============ Edit metadata ============

  Future<void> _showEditDialog() async {
    final titleCtrl = TextEditingController(text: _convTitle);
    final summaryCtrl = TextEditingController(text: _convSummary ?? '');
    final noteCtrl = TextEditingController(text: _convNote ?? '');

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr("Edit")),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: titleCtrl,
              decoration: InputDecoration(labelText: tr("Title")),
            ),
            SizedBox(height: 8),
            TextField(
              controller: summaryCtrl,
              decoration: InputDecoration(labelText: tr("Summary")),
              maxLines: 3,
            ),
            SizedBox(height: 8),
            TextField(
              controller: noteCtrl,
              decoration: InputDecoration(
                labelText: tr("Notes"),
                hintText: tr("For example: #important #todo"),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr("Cancel")),
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
                _api.getConversation(_conversationId!).then((c) {
                  if (c != null) {
                    _api.updateConversation(
                      Conversation(
                        uuid: c.uuid,
                        title: _convTitle,
                        summary: _convSummary,
                        userNote: _convNote,
                        forkedFrom: c.forkedFrom,
                        createdAt: c.createdAt,
                        lastActiveAt: c.lastActiveAt,
                        lastArchivedAt: c.lastArchivedAt,
                      ),
                    );
                  }
                });
              }
              Navigator.pop(ctx);
            },
            child: Text(tr("Save")),
          ),
        ],
      ),
    );
  }

  // ============ Archive — handled by VPS ============

  Future<void> _archive() async {
    final instructionController = TextEditingController();
    String? instruction;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr("Archive this conversation")),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              tr("AI will create titles and summaries and extract memories."),
            ),
            SizedBox(height: 8),
            TextField(
              controller: instructionController,
              decoration: InputDecoration(
                hintText: tr("Any special instructions? (optional)"),
                border: OutlineInputBorder(),
              ),
              maxLines: 2,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr("Cancel")),
          ),
          TextButton(
            onPressed: () {
              instruction = instructionController.text.trim();
              Navigator.pop(ctx, true);
            },
            child: Text(tr("Archive")),
          ),
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
            SnackBar(
              content: Text(tr("Split into {0} diary entries", [segments])),
            ),
          );
          Navigator.pop(context);
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(tr("Archived: {0}", [title ?? _convTitle]))),
          );
        }
        if (title != null) setState(() => _convTitle = title);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr("Could not archive: {0}", [e]))),
      );
    }
  }

  // ============ UI helpers (same as old version) ============

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients &&
          _scrollController.position.maxScrollExtent > 0) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });
  }

  List<Map<String, dynamic>> get _displayMessages => _messages
      .where(
        (m) =>
            m['content'] != null &&
            (m['role'] == 'user' || m['role'] == 'assistant'),
      )
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
    final date = dt.year == now.year
        ? DateFormat.MMMd(AppLanguage.locale).format(dt)
        : DateFormat.yMMMd(AppLanguage.locale).format(dt);
    return '$date $timeStr';
  }

  // ============ Build (UI structure completely unchanged) ============

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
            title: Text(tr("AI is replying")),
            content: Text(
              tr("A reply is in progress. Leave this conversation?"),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(tr("Stay")),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(tr("Leave")),
              ),
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
                    Flexible(
                      child: Text(_convTitle, overflow: TextOverflow.ellipsis),
                    ),
                    SizedBox(width: 4),
                    Icon(Icons.edit, size: 14, color: Colors.white70),
                  ],
                ),
                if (_convSummary != null && _convSummary!.isNotEmpty)
                  Text(
                    _convSummary!,
                    style: TextStyle(fontSize: 11, color: Colors.white70),
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          actions: [
            if (_messages.length >= 2)
              IconButton(
                icon: Icon(Icons.archive_outlined),
                tooltip: tr("Archive"),
                onPressed: _archive,
              ),
          ],
        ),
        body: Column(
          children: [
            Expanded(
              child: _messages.isEmpty
                  ? Center(child: Text(tr("Start a conversation")))
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
                            !isUser &&
                            reasoning != null &&
                            reasoning.isNotEmpty;

                        final bubble = Container(
                          margin: EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 4,
                          ),
                          padding: EdgeInsets.all(12),
                          constraints: BoxConstraints(
                            maxWidth: MediaQuery.of(context).size.width * 0.8,
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
                                    margin: EdgeInsets.only(bottom: 8),
                                    padding: EdgeInsets.all(8),
                                    decoration: BoxDecoration(
                                      color: Colors.yellow.shade50,
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(
                                        color: Colors.yellow.shade200,
                                      ),
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
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
                                            SizedBox(width: 4),
                                            Text(
                                              tr("Reasoning and tools"),
                                              style: TextStyle(
                                                fontSize: 12,
                                                fontWeight: FontWeight.bold,
                                                color: Colors.orange.shade700,
                                              ),
                                            ),
                                          ],
                                        ),
                                        if (_expandedReasoning.contains(
                                          index,
                                        )) ...[
                                          SizedBox(height: 4),
                                          SelectableText(
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
                              SelectionArea(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: _buildContentWithLatex(
                                    msg['content']!,
                                    context,
                                  ),
                                ),
                              ),
                              if (timeText.isNotEmpty)
                                Padding(
                                  padding: EdgeInsets.only(top: 4),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        timeText,
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: Colors.grey.shade600,
                                        ),
                                      ),
                                      SizedBox(width: 8),
                                      GestureDetector(
                                        onTap: () {
                                          Clipboard.setData(
                                            ClipboardData(
                                              text: msg['content']!,
                                            ),
                                          );
                                          ScaffoldMessenger.of(
                                            context,
                                          ).showSnackBar(
                                            SnackBar(
                                              content: Text(tr("Copied")),
                                              duration: Duration(seconds: 1),
                                            ),
                                          );
                                        },
                                        child: Icon(
                                          Icons.copy,
                                          size: 13,
                                          color: Colors.grey.shade500,
                                        ),
                                      ),
                                    ],
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
              padding: EdgeInsets.all(8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Voice status hint
                  /* Voice disabled.
                  ValueListenableBuilder<VoiceState>(
                    valueListenable: _voiceController.state,
                    builder: (context, state, _) {
                      if (state == VoiceState.idle) return SizedBox.shrink();
                      if (state == VoiceState.loading) {
                        return Container(
                          width: double.infinity,
                          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          margin: EdgeInsets.only(bottom: 4),
                          decoration: BoxDecoration(
                            color: Colors.blue.shade50,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(tr("Loading speech model…"),
                            style: TextStyle(fontSize: 13, color: Colors.blue.shade700)),
                        );
                      }
                      return ValueListenableBuilder<String>(
                        valueListenable: _voiceController.partialText,
                        builder: (context, partial, _) {
                          return Container(
                            width: double.infinity,
                            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                            margin: EdgeInsets.only(bottom: 4),
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
                                  ? (partial.isNotEmpty ? tr("Listening: {0}", [partial]) : tr("Listening…"))
                                  : state == VoiceState.processing
                                      ? tr("AI is thinking…")
                                      : tr("AI is replying…"),
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
                  // Input row
                  */
                  Row(
                    children: [
                      // Microphone button
                      // VoiceMicButton(controller: _voiceController),
                      Expanded(
                        child: CallbackShortcuts(
                          bindings: {
                            SingleActivator(
                              LogicalKeyboardKey.enter,
                              control: true,
                            ): () {
                              if (!_isLoading) _sendMessage();
                            },
                          },
                          child: TextField(
                            controller: _controller,
                            focusNode: _focusNode,
                            maxLines: 10,
                            minLines: 1,
                            textInputAction: TextInputAction.newline,
                            decoration: InputDecoration(
                              hintText: tr(
                                "Write a message… (Enter for a new line, Ctrl+Enter to send)",
                              ),
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                      ),
                      SizedBox(width: 8),
                      IconButton(
                        onPressed: _isLoading ? null : _sendMessage,
                        icon: _isLoading
                            ? SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : Icon(Icons.send),
                      ),
                    ],
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
