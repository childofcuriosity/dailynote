import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../services/clients.dart';
import '../services/supabase_service.dart';
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

class _ConvWithTags {
  final Conversation conv;
  final List<String> tags;
  _ConvWithTags(this.conv, this.tags);
}

class _HomePageState extends State<HomePage> {
  final _supa = SupaService(supaClient);
  final _ai = AiService(apiKey: Secrets.aiApiKey, baseUrl: Secrets.aiBaseUrl, model: Secrets.aiModel);
  List<_ConvWithTags> _allConversations = []; // 全量缓存
  Map<String, List<_ConvWithTags>> _grouped = {};
  List<Map<String, dynamic>> _tags = [];
  final Set<String> _selectedTags = {};
  bool _pinnedOnly = false;
  bool _showHidden = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await _loadTags();
    await _loadConversations(fromRemote: true);
    await _autoArchiveDirty();
  }

  Future<void> _loadTags() async {
    _tags = await _supa.getTags();
  }

  /// [fromRemote] 为 true 时重新拉取 Supabase（进聊天页回来后），否则纯本地过滤
  Future<void> _loadConversations({bool fromRemote = false}) async {
    if (!mounted) return;
    if (_allConversations.isEmpty || fromRemote) {
      final all = await _supa.getConversations();
      final allTags = await _supa.getAllConversationTags();
      _allConversations = all.map((c) => _ConvWithTags(c, allTags[c.uuid] ?? <String>[])).toList();
      await _loadTags();
    }
    // 纯本地过滤
    final filtered = _allConversations.where((ct) {
      if (ct.conv.hidden && !_showHidden) return false;
      if (_pinnedOnly && !ct.conv.pinned) return false;
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

  Future<void> _autoArchiveDirty() async {
    final dirtyConvs = await _supa.getDirtyBeforeToday();
    if (dirtyConvs.isEmpty) return;
    for (final conv in dirtyConvs) {
      try {
        final msgs = await _supa.getMessages(conv.uuid);
        final msgList = msgs.map((m) => {'role': m.role, 'content': m.content}).toList();
        if (msgList.length < 2) continue;
        final existingMemories = await _supa.getAllMemoryContents();
        final result = await _ai.autoArchive(messages: msgList, existingSummary: conv.summary, existingMemories: existingMemories);
        await _supa.updateConversation(Conversation(
          uuid: conv.uuid, title: result['title'] as String? ?? conv.title,
          summary: result['summary'] as String? ?? conv.summary,
          userNote: conv.userNote, forkedFrom: conv.forkedFrom,
          pinned: conv.pinned,
          createdAt: conv.createdAt, lastActiveAt: conv.lastActiveAt,
          lastArchivedAt: DateTime.now(),
        ));
        final tags = (result['tags'] as List<dynamic>?)?.map((t) => t.toString()).toList() ?? [];
        await _supa.applyTags(conv.uuid, tags);
        final memories = result['memories'] as List<dynamic>?;
        if (memories != null) {
          for (final m in memories) {
            if (m is String && m.trim().isNotEmpty) {
              await _supa.insertMemory(m.trim(), sourceConvId: conv.uuid);
            }
          }
        }
      } catch (_) {}
    }
    await _loadConversations(fromRemote: true);
  }

  Future<void> _applyTags(String convId, List<String> tagNames) async {
    final tagIds = <String>[];
    for (final name in tagNames) {
      tagIds.add(await _supa.createTag(name));
    }
    await _supa.setConversationTags(convId, tagIds);
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
                    await _supa.createTag(nameCtrl.text.trim());
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
                      await _supa.deleteTag(id);
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
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
            TextButton(onPressed: () async {
              await _supa.updateConversation(Conversation(
                uuid: conv.uuid,
                title: titleCtrl.text.trim().isEmpty ? conv.title : titleCtrl.text.trim(),
                summary: conv.summary,
                userNote: noteCtrl.text.trim().isEmpty ? null : noteCtrl.text.trim(),
                forkedFrom: conv.forkedFrom, pinned: pinned, hidden: hidden,
                createdAt: conv.createdAt, lastActiveAt: conv.lastActiveAt,
                lastArchivedAt: conv.lastArchivedAt,
              ));
              await _applyTags(conv.uuid, selectedTags);
              Navigator.pop(ctx);
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
        widgets.add(ListTile(
          title: Row(children: [
            if (ct.conv.pinned) const Icon(Icons.star, size: 16, color: Colors.amber),
            if (ct.conv.hidden) const Icon(Icons.visibility_off, size: 16, color: Colors.grey),
            const SizedBox(width: 4),
            Expanded(child: Text(ct.conv.title,
              style: TextStyle(color: ct.conv.hidden ? Colors.grey : null),
            )),
          ]),
          subtitle: Text(ct.conv.summary ?? ''),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            if (ct.tags.isNotEmpty)
              ...ct.tags.take(3).map((t) => Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Chip(label: Text(t, style: const TextStyle(fontSize: 9)), materialTapTargetSize: MaterialTapTargetSize.shrinkWrap),
              )),
            if (ct.conv.userNote != null && ct.conv.userNote!.isNotEmpty)
              Tooltip(message: ct.conv.userNote!, child: Icon(Icons.push_pin, size: 16, color: Colors.orange.shade400)),
            const Icon(Icons.chevron_right),
          ]),
          onTap: () async {
            await Navigator.push(context, MaterialPageRoute(builder: (_) => ChatPage(conversationId: ct.conv.uuid)));
            _loadConversations(fromRemote: true);
          },
          onLongPress: () => _showEditDialog(ct),
        ));
        widgets.add(const Divider(indent: 16));
      }
    }
    return widgets;
  }

  // ============ Build ============

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('日记助手'),
        actions: [
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
          IconButton(icon: const Icon(Icons.label_outline), tooltip: '管理标签', onPressed: _showTagManager),
          IconButton(icon: const Icon(Icons.psychology_outlined), tooltip: '记忆管理', onPressed: () async {
            await Navigator.push(context, MaterialPageRoute(builder: (_) => const MemoriesPage()));
            _loadConversations(fromRemote: true);
          }),
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
      floatingActionButton: FloatingActionButton(
        onPressed: () async {
          await Navigator.push(context, MaterialPageRoute(builder: (_) => const ChatPage()));
          _loadConversations();
        },
        child: const Icon(Icons.add),
      ),
    );
  }
}
