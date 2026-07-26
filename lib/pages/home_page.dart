import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../services/database.dart';
import '../services/ai_service.dart';
import '../services/secrets.dart';
import '../models/conversation.dart';
import 'chat_page.dart';
import 'memories_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _db = DatabaseService();
  final _ai = AiService(
    apiKey: Secrets.aiApiKey,
    baseUrl: Secrets.aiBaseUrl,
    model: Secrets.aiModel,
  );
  Map<String, List<_ConvWithTags>> _grouped = {};
  List<Map<String, dynamic>> _tags = [];
  final Set<int> _selectedTagIds = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await _loadTags();
    await _loadConversations();
    await _autoArchiveDirty();
  }

  Future<void> _loadTags() async {
    _tags = await _db.getTags();
  }

  Future<void> _loadConversations() async {
    final list = await _db.getConversations(
        tagIds: _selectedTagIds.isEmpty ? null : _selectedTagIds.toList());

    // 为每个会话加载标签
    final withTags = <_ConvWithTags>[];
    for (final conv in list) {
      final tags = await _db.getTagsForConversation(conv.id!);
      withTags.add(_ConvWithTags(conv, tags));
    }

    final dateFormat = DateFormat('yyyy年M月d日 EEEE', 'zh_CN');
    final grouped = <String, List<_ConvWithTags>>{};
    for (final ct in withTags) {
      final key = dateFormat.format(ct.conv.lastActiveAt);
      grouped.putIfAbsent(key, () => []).add(ct);
    }
    setState(() {
      _grouped = grouped;
      _loading = false;
    });
  }

  Future<void> _autoArchiveDirty() async {
    final dirtyConvs = await _db.getDirtyBeforeToday();
    if (dirtyConvs.isEmpty) return;

    for (final conv in dirtyConvs) {
      try {
        final msgs = await _db.getMessages(conv.id!);
        final msgList =
            msgs.map((m) => {'role': m.role, 'content': m.content}).toList();
        if (msgList.length < 2) continue;

        final existingMemories = (await _db.getAllMemories())
            .map((m) => m['content'] as String)
            .toList();
        final result = await _ai.autoArchive(
          messages: msgList,
          existingSummary: conv.summary,
          existingMemories: existingMemories,
        );

        await _db.updateConversation(Conversation(
          id: conv.id,
          title: result['title'] as String? ?? conv.title,
          summary: result['summary'] as String? ?? conv.summary,
          userNote: conv.userNote,
          forkedFrom: conv.forkedFrom,
          createdAt: conv.createdAt,
          lastActiveAt: conv.lastActiveAt,
          lastArchivedAt: DateTime.now(),
        ));

        // 处理标签
        final tags = (result['tags'] as List<dynamic>?)
                ?.map((t) => t.toString())
                .toList() ??
            [];
        await _applyTags(conv.id!, tags);

        // 记忆
        final memories = result['memories'] as List<dynamic>?;
        if (memories != null) {
          for (final m in memories) {
            if (m is String && m.trim().isNotEmpty) {
              await _db.insertMemory(m.trim(), sourceConvId: conv.id);
            }
          }
        }
      } catch (_) {}
    }
    await _loadConversations();
  }
  Future<void> _applyTags(int convId, List<String> tagNames) async {
    final tagIds = <int>[];
    for (final name in tagNames) {
      final tid = await _db.createTag(name);
      tagIds.add(tid);
    }
    await _db.setConversationTags(convId, tagIds);
    await _loadTags(); // 刷新标签库（可能有新增）
  }

  // ============ 标签编辑弹窗 ============

  Future<void> _showEditDialog(_ConvWithTags ct) async {
    final conv = ct.conv;
    final titleCtrl = TextEditingController(text: conv.title);
    final noteCtrl = TextEditingController(text: conv.userNote ?? '');
    final selectedTags = List<String>.from(ct.tags);

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('编辑'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: titleCtrl,
                decoration: const InputDecoration(labelText: '标题'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: noteCtrl,
                decoration: const InputDecoration(
                    labelText: '备注', hintText: '如：#重要 #待办'),
              ),
              const SizedBox(height: 12),
              const Text('标签', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: _tags.map((t) {
                  final name = t['name'] as String;
                  final isSelected = selectedTags.contains(name);
                  return FilterChip(
                    label: Text(name),
                    selected: isSelected,
                    onSelected: (val) {
                      setDialogState(() {
                        if (val) {
                          selectedTags.add(name);
                        } else {
                          selectedTags.remove(name);
                        }
                      });
                    },
                  );
                }).toList(),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () async {
                final newTitle = titleCtrl.text.trim().isEmpty
                    ? conv.title
                    : titleCtrl.text.trim();
                await _db.updateConversation(Conversation(
                  id: conv.id,
                  title: newTitle,
                  summary: conv.summary,
                  userNote: noteCtrl.text.trim().isEmpty
                      ? null
                      : noteCtrl.text.trim(),
                  forkedFrom: conv.forkedFrom,
                  createdAt: conv.createdAt,
                  lastActiveAt: conv.lastActiveAt,
                  lastArchivedAt: conv.lastArchivedAt,
                ));
                await _applyTags(conv.id!, selectedTags);
                Navigator.pop(ctx);
                _loadConversations();
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
  }

  // ============ 标签管理弹窗 ============

  Future<void> _showTagManager() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('管理标签'),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 添加新标签
                Row(children: [
                  Expanded(
                    child: TextField(
                      decoration: const InputDecoration(
                        hintText: '新标签名',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      onSubmitted: (name) async {
                        if (name.trim().isNotEmpty) {
                          await _db.createTag(name.trim());
                          setDialogState(() {});
                          await _loadTags();
                        }
                      },
                    ),
                  ),
                ]),
                const SizedBox(height: 12),
                // 现有标签列表
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: _tags.map((t) {
                      final name = t['name'] as String;
                      final id = t['id'] as int;
                      return ListTile(
                        dense: true,
                        title: Text(name),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline, size: 20),
                          onPressed: () async {
                            await _db.deleteTag(id);
                            setDialogState(() {});
                            await _loadTags();
                            _loadConversations();
                          },
                        ),
                      );
                    }).toList(),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                _loadConversations();
              },
              child: const Text('完成'),
            ),
          ],
        ),
      ),
    );
  }

  // ============ UI ============

  Widget _buildTagChips() {
    if (_tags.isEmpty) return const SizedBox.shrink();
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          FilterChip(
            label: Text('全部${_selectedTagIds.isEmpty ? "" : " ✕"}'),
            selected: _selectedTagIds.isEmpty,
            onSelected: (_) {
              setState(() => _selectedTagIds.clear());
              _loadConversations();
            },
          ),
          const SizedBox(width: 6),
          ...(_tags.map((t) {
            final id = t['id'] as int;
            final name = t['name'] as String;
            final selected = _selectedTagIds.contains(id);
            return Padding(
              padding: const EdgeInsets.only(right: 6),
              child: FilterChip(
                label: Text(name),
                selected: selected,
                onSelected: (val) {
                  setState(() {
                    if (val) {
                      _selectedTagIds.add(id);
                    } else {
                      _selectedTagIds.remove(id);
                    }
                  });
                  _loadConversations();
                },
              ),
            );
          })),
        ],
      ),
    );
  }

  List<Widget> _buildTimeline() {
    final widgets = <Widget>[];
    for (final date in _grouped.keys) {
      widgets.add(Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(date,
            style: const TextStyle(
                fontSize: 15, fontWeight: FontWeight.bold, color: Colors.teal)),
      ));
      for (final ct in _grouped[date]!) {
        widgets.add(ListTile(
          title: Text(ct.conv.title),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (ct.conv.summary != null && ct.conv.summary!.isNotEmpty)
                Text(ct.conv.summary!, maxLines: 1, overflow: TextOverflow.ellipsis),
              if (ct.tags.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Wrap(
                    spacing: 4,
                    children: ct.tags.map((t) => Chip(
                      label: Text(t, style: const TextStyle(fontSize: 10)),
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                    )).toList(),
                  ),
                ),
            ],
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (ct.conv.userNote != null && ct.conv.userNote!.isNotEmpty)
                Tooltip(
                  message: ct.conv.userNote!,
                  child: Icon(Icons.push_pin, size: 16,
                      color: Colors.orange.shade400),
                ),
              const SizedBox(width: 4),
              const Icon(Icons.chevron_right),
            ],
          ),
          onTap: () async {
            await Navigator.push(context,
              MaterialPageRoute(builder: (_) => ChatPage(conversationId: ct.conv.id)),
            );
            _loadConversations();
                  },
          onLongPress: () => _showEditDialog(ct),
        ));
        widgets.add(const Divider(indent: 16));
      }
    }
    return widgets;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('日记助手'),
        actions: [
          IconButton(
            icon: const Icon(Icons.label_outline),
            tooltip: '管理标签',
            onPressed: _showTagManager,
          ),
          IconButton(
            icon: const Icon(Icons.psychology_outlined),
            tooltip: '记忆管理',
            onPressed: () async {
              await Navigator.push(context,
                MaterialPageRoute(builder: (_) => const MemoriesPage()),
              );
            },
          ),
        ],
      ),
      body: Column(
        children: [
          _buildTagChips(),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _grouped.isEmpty
                    ? const Center(child: Text('还没有日记'))
                    : ListView(children: _buildTimeline()),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () async {
          await Navigator.push(context,
            MaterialPageRoute(builder: (_) => const ChatPage()),
          );
          _loadConversations();
              },
        child: const Icon(Icons.add),
      ),
    );
  }
}

/// 轻量 wrapper：会话 + 其标签名列表
class _ConvWithTags {
  final Conversation conv;
  final List<String> tags;
  _ConvWithTags(this.conv, this.tags);
}
