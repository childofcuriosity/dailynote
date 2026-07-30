import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../services/api_service.dart';
import '../models/conversation.dart';
import 'chat_page.dart';
import 'memories_page.dart';
import 'soul_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _ConvWithTags {
  final Conversation conv;
  final List<String> tags;
  _ConvWithTags(this.conv, this.tags);
}

class _HomePageState extends State<HomePage> {
  final _api = ApiService();
  List<_ConvWithTags> _allConversations = []; // 全量缓存
  Map<String, List<_ConvWithTags>> _grouped = {};
  List<Map<String, dynamic>> _tags = [];
  final Set<String> _selectedTags = {};
  bool _pinnedOnly = false;
  bool _showHidden = false;
  bool _hideAi = true;
  bool _hideArchived = true;
  bool _loading = true;
  bool _selectionMode = false;
  final Set<String> _selectedConvIds = {};

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await _loadTags();
    await _loadConversations(fromRemote: true);
    // 自动归档已交给 VPS agent 后台处理
  }

  Future<void> _loadTags() async {
    _tags = await _api.getTags();
  }

  /// [fromRemote] 为 true 时重新拉取 Supabase（进聊天页回来后），否则纯本地过滤
  Future<void> _loadConversations({bool fromRemote = false}) async {
    if (!mounted) return;
    if (_allConversations.isEmpty || fromRemote) {
      final all = await _api.getConversations();
      final allTags = await _api.getAllConversationTags();
      _allConversations = all.map((c) => _ConvWithTags(c, allTags[c.uuid] ?? <String>[])).toList();
      await _loadTags();
    }
    // 纯本地过滤
    final filtered = _allConversations.where((ct) {
      if (ct.conv.hidden && !_showHidden) return false;
      if (_pinnedOnly && !ct.conv.pinned) return false;
      if (_hideAi && ct.conv.isAiGenerated) return false;
      if (_hideArchived && ct.conv.archived) return false;
      if (_selectedTags.isNotEmpty && !ct.tags.any((t) => _selectedTags.contains(t))) return false;
      return true;
    }).toList();
    final dateFormat = DateFormat('yyyy年M月d日 EEEE', 'zh_CN');
    final grouped = <String, List<_ConvWithTags>>{};
    for (final ct in filtered) {
      final key = dateFormat.format(ct.conv.lastActiveAt);
      grouped.putIfAbsent(key, () => []).add(ct);
    }
    setState(() {
      _grouped = grouped;
      _loading = false;
    });
  }

  Future<void> _applyTags(String convId, List<String> tagNames) async {
    // VPS setConversationTags 内部已做 get_or_create_tag，直接传名字即可
    await _api.setConversationTags(convId, tagNames);
    await _loadTags();
  }

  // ============ Tag Manager ============

  Future<void> _showTagManager() async {
    final nameCtrl = TextEditingController();
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('管理标签'),
          content: SizedBox(width: double.maxFinite, child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(children: [
                Expanded(child: TextField(controller: nameCtrl, decoration: const InputDecoration(hintText: '新标签名', border: OutlineInputBorder()))),
                const SizedBox(width: 8),
                IconButton(icon: const Icon(Icons.add_circle), onPressed: () async {
                  if (nameCtrl.text.trim().isNotEmpty) {
                    await _api.createTag(nameCtrl.text.trim());
                    nameCtrl.clear();
                    await _loadTags();
                    setDialogState(() {});
                  }
                }),
              ]),
              const SizedBox(height: 8),
              SizedBox(height: 200, child: ListView(
                children: _tags.map((t) {
                  final name = t['name'] as String;
                  final id = t['id'] as String;
                  return ListTile(
                    title: Text(name),
                    trailing: IconButton(icon: const Icon(Icons.delete_outline, size: 18), onPressed: () async {
                      await _api.deleteTag(id);
                      await _loadTags();
                      setDialogState(() {});
                    }),
                  );
                }).toList(),
              )),
            ],
          )),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('关闭'))],
        ),
      ),
    );
  }

  // ============ Edit Dialog ============

  Future<void> _showEditDialog(_ConvWithTags ct) async {
    final conv = ct.conv;
    final titleCtrl = TextEditingController(text: conv.title);
    final noteCtrl = TextEditingController(text: conv.userNote ?? '');
    final selectedTags = List<String>.from(ct.tags);
    bool pinned = conv.pinned;
    bool hidden = conv.hidden;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('编辑'),
          content: Column(
            mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(controller: titleCtrl, decoration: const InputDecoration(labelText: '标题')),
              const SizedBox(height: 8),
              TextField(controller: noteCtrl, decoration: const InputDecoration(labelText: '备注', hintText: '如：#重要 #待办')),
              const SizedBox(height: 12),
              SwitchListTile(title: const Text('精选置顶'), value: pinned, onChanged: (v) => setDialogState(() => pinned = v)),
              SwitchListTile(title: const Text('隐藏'), value: hidden, onChanged: (v) => setDialogState(() => hidden = v)),
              const Text('标签', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Wrap(spacing: 6, runSpacing: 4, children: _tags.map((t) {
                final name = t['name'] as String;
                return FilterChip(
                  label: Text(name), selected: selectedTags.contains(name),
                  onSelected: (val) => setDialogState(() {
                    if (val) { selectedTags.add(name); } else { selectedTags.remove(name); }
                  }),
                );
              }).toList()),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () async {
                Navigator.pop(ctx);
                final confirmed = await showDialog<bool>(
                  context: this.context,
                  builder: (c) => AlertDialog(
                    title: const Text('确认删除'),
                    content: Text('删除「${conv.title}」及其所有消息？\n此操作不可撤销。'),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
                      TextButton(
                        onPressed: () => Navigator.pop(c, true),
                        child: const Text('删除', style: TextStyle(color: Colors.red)),
                      ),
                    ],
                  ),
                );
                if (confirmed == true) {
                  await _api.deleteConversation(conv.uuid);
                  _loadConversations(fromRemote: true);
                }
              },
              child: const Text('删除', style: TextStyle(color: Colors.red)),
            ),
            TextButton(onPressed: () async {
              final newTitle = titleCtrl.text.trim().isEmpty ? conv.title : titleCtrl.text.trim();
              final newNote = noteCtrl.text.trim().isEmpty ? null : noteCtrl.text.trim();
              Navigator.pop(ctx);
              await _api.updateConversation(Conversation(
                uuid: conv.uuid, title: newTitle,
                summary: conv.summary, userNote: newNote,
                forkedFrom: conv.forkedFrom, pinned: pinned, hidden: hidden,
                createdAt: conv.createdAt, lastActiveAt: conv.lastActiveAt,
                lastArchivedAt: conv.lastArchivedAt,
              ));
              await _applyTags(conv.uuid, selectedTags);
              _loadConversations(fromRemote: true);
            }, child: const Text('保存')),
          ],
        ),
      ),
    );
  }

  // ============ Timeline ============

  List<Widget> _buildTimeline() {
    final widgets = <Widget>[];
    for (final date in _grouped.keys) {
      widgets.add(Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(date, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.teal)),
      ));
      for (final ct in _grouped[date]!) {
        final selected = _selectedConvIds.contains(ct.conv.uuid);
        widgets.add(ListTile(
          leading: _selectionMode
              ? Checkbox(value: selected, onChanged: (_) => _toggleSelection(ct.conv.uuid))
              : null,
          title: Row(children: [
            if (ct.conv.pinned) const Icon(Icons.star, size: 16, color: Colors.amber),
            if (ct.conv.hidden) const Icon(Icons.visibility_off, size: 16, color: Colors.grey),
            if (ct.conv.isAiGenerated) const Icon(Icons.smart_toy, size: 16, color: Colors.teal),
            if (ct.conv.archived) const Icon(Icons.archive, size: 16, color: Colors.brown),
            const SizedBox(width: 4),
            Expanded(child: Text(ct.conv.title,
              style: TextStyle(color: ct.conv.hidden ? Colors.grey : null),
            )),
          ]),
          subtitle: Text(ct.conv.summary ?? ''),
          trailing: _selectionMode
              ? null
              : Row(mainAxisSize: MainAxisSize.min, children: [
                  if (ct.tags.isNotEmpty)
                    ...ct.tags.take(3).map((t) => Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: Chip(label: Text(t, style: const TextStyle(fontSize: 9)), materialTapTargetSize: MaterialTapTargetSize.shrinkWrap),
                    )),
                  if (ct.conv.userNote != null && ct.conv.userNote!.isNotEmpty)
                    Tooltip(message: ct.conv.userNote!, child: Icon(Icons.push_pin, size: 16, color: Colors.orange.shade400)),
                  const Icon(Icons.chevron_right),
                ]),
          onTap: _selectionMode
              ? () => _toggleSelection(ct.conv.uuid)
              : () async {
                  await Navigator.push(context, MaterialPageRoute(builder: (_) => ChatPage(conversationId: ct.conv.uuid)));
                  _loadConversations(fromRemote: true);
                },
          onLongPress: _selectionMode ? null : () => _showEditDialog(ct),
        ));
        widgets.add(const Divider(indent: 16));
      }
    }
    return widgets;
  }

  // ============ Build ============

  // ============ 批量选择 ============

  void _toggleSelection(String convId) {
    setState(() {
      if (_selectedConvIds.contains(convId)) {
        _selectedConvIds.remove(convId);
        if (_selectedConvIds.isEmpty) _selectionMode = false;
      } else {
        _selectedConvIds.add(convId);
      }
    });
  }

  void _enterSelectionMode(String convId) {
    setState(() {
      _selectionMode = true;
      _selectedConvIds.add(convId);
    });
  }

  void _exitSelectionMode() {
    setState(() {
      _selectionMode = false;
      _selectedConvIds.clear();
    });
  }

  Future<void> _batchDelete() async {
    final ids = Set<String>.from(_selectedConvIds);
    for (final id in ids) {
      await _api.deleteConversation(id);
    }
    _exitSelectionMode();
    _loadConversations(fromRemote: true);
  }

  Future<void> _batchPin() async {
    final ids = Set<String>.from(_selectedConvIds);
    for (final id in ids) {
      final conv = _allConversations.firstWhere((c) => c.conv.uuid == id).conv;
      await _api.updateConversation(Conversation(
        uuid: id, title: conv.title, summary: conv.summary,
        userNote: conv.userNote, forkedFrom: conv.forkedFrom,
        pinned: true, hidden: conv.hidden,
        createdAt: conv.createdAt, lastActiveAt: conv.lastActiveAt,
        lastArchivedAt: conv.lastArchivedAt,
      ));
    }
    _exitSelectionMode();
    _loadConversations(fromRemote: true);
  }

  Future<void> _batchHide() async {
    final ids = Set<String>.from(_selectedConvIds);
    for (final id in ids) {
      final conv = _allConversations.firstWhere((c) => c.conv.uuid == id).conv;
      await _api.updateConversation(Conversation(
        uuid: id, title: conv.title, summary: conv.summary,
        userNote: conv.userNote, forkedFrom: conv.forkedFrom,
        pinned: conv.pinned, hidden: true,
        createdAt: conv.createdAt, lastActiveAt: conv.lastActiveAt,
        lastArchivedAt: conv.lastArchivedAt,
      ));
    }
    _exitSelectionMode();
    _loadConversations(fromRemote: true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: _selectionMode
            ? Text('已选 ${_selectedConvIds.length} 项')
            : const Text('日记助手'),
        leading: _selectionMode
            ? IconButton(icon: const Icon(Icons.close), onPressed: _exitSelectionMode)
            : null,
        actions: _selectionMode
            ? [
                IconButton(
                  icon: const Icon(Icons.select_all),
                  tooltip: '全选',
                  onPressed: () => setState(() {
                    for (final list in _grouped.values) {
                      for (final ct in list) {
                        _selectedConvIds.add(ct.conv.uuid);
                      }
                    }
                  }),
                ),
              ]
            : [
          IconButton(
            icon: Icon(_pinnedOnly ? Icons.star : Icons.star_border),
            tooltip: _pinnedOnly ? '显示全部' : '只看精选',
            onPressed: () {
              setState(() => _pinnedOnly = !_pinnedOnly);
              _loadConversations(fromRemote: false);
            },
          ),
          IconButton(
            icon: Icon(_showHidden ? Icons.visibility : Icons.visibility_off, size: 20),
            tooltip: _showHidden ? '隐藏归档' : '显示全部',
            onPressed: () {
              setState(() => _showHidden = !_showHidden);
              _loadConversations(fromRemote: false);
            },
          ),
          IconButton(
            icon: Icon(_hideAi ? Icons.travel_explore : Icons.travel_explore,
                color: _hideAi ? null : Colors.orange),
            tooltip: _hideAi ? '显示 AI 发现' : '隐藏 AI 发现',
            onPressed: () {
              setState(() => _hideAi = !_hideAi);
              _loadConversations(fromRemote: false);
            },
          ),
          IconButton(
            icon: Icon(_hideArchived ? Icons.archive_outlined : Icons.archive,
                color: _hideArchived ? null : Colors.brown),
            tooltip: _hideArchived ? '显示已归档' : '隐藏已归档',
            onPressed: () {
              setState(() => _hideArchived = !_hideArchived);
              _loadConversations(fromRemote: false);
            },
          ),
          IconButton(icon: const Icon(Icons.label_outline), tooltip: '管理标签', onPressed: _showTagManager),
          IconButton(icon: const Icon(Icons.psychology_outlined), tooltip: '记忆管理', onPressed: () async {
            await Navigator.push(context, MaterialPageRoute(builder: (_) => const MemoriesPage()));
            _loadConversations(fromRemote: true);
          }),
          IconButton(icon: const Icon(Icons.auto_awesome, size: 20), tooltip: 'AI Soul', onPressed: () async {
            await Navigator.push(context, MaterialPageRoute(builder: (_) => const SoulPage()));
          }),
          IconButton(
            icon: const Icon(Icons.checklist, size: 20),
            tooltip: '批量选择',
            onPressed: () => setState(() => _selectionMode = true),
          ),
        ],
      ),
      body: Column(children: [
        if (_tags.isNotEmpty)
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              children: _tags.map((t) {
                final name = t['name'] as String;
                final selected = _selectedTags.contains(name);
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: FilterChip(
                    label: Text(name),
                    selected: selected,
                    onSelected: (v) {
                      setState(() {
                        if (v) { _selectedTags.add(name); } else { _selectedTags.remove(name); }
                      });
                      _loadConversations(fromRemote: false); // 本地过滤
                    },
                  ),
                );
              }).toList(),
            ),
          ),
        Expanded(child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _grouped.isEmpty
                ? const Center(child: Text('还没有日记'))
                : ListView(children: _buildTimeline())),
      ]),
      floatingActionButton: _selectionMode
          ? null
          : FloatingActionButton(
              onPressed: () async {
                await Navigator.push(context, MaterialPageRoute(builder: (_) => const ChatPage()));
                _loadConversations();
              },
              child: const Icon(Icons.add),
            ),
      bottomNavigationBar: _selectionMode && _selectedConvIds.isNotEmpty
          ? BottomAppBar(
              child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                IconButton(
                  icon: const Icon(Icons.delete, color: Colors.red),
                  tooltip: '删除',
                  onPressed: _batchDelete,
                ),
                IconButton(
                  icon: const Icon(Icons.star, color: Colors.amber),
                  tooltip: '收藏',
                  onPressed: _batchPin,
                ),
                IconButton(
                  icon: const Icon(Icons.visibility_off),
                  tooltip: '隐藏',
                  onPressed: _batchHide,
                ),
              ]),
            )
          : null,
    );
  }
}
