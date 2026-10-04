import '../services/l10n.dart';
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
  List<_ConvWithTags> _allConversations = []; // Full cache
  Map<String, List<_ConvWithTags>> _grouped = {};
  List<Map<String, dynamic>> _tags = [];
  final Set<String> _selectedTags = {};
  bool _pinnedOnly = false;
  bool _showHidden = false;
  bool _hideAi = true;
  bool _hideArchived = true;
  bool _loading = true;
  bool _loadFailed = false;
  bool _selectionMode = false;
  final Set<String> _selectedConvIds = {};

  @override
  void initState() {
    super.initState();
    _hideAi = ApiService.account != 'demo';
    _init();
  }

  Future<void> _init() async {
    setState(() {
      _loading = true;
      _loadFailed = false;
    });
    try {
      await _loadTags();
      if (!mounted) return;
      await _loadConversations(fromRemote: true);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadFailed = true;
      });
    }
    // Auto-archiving is now handled by the VPS agent in the background
  }

  Future<void> _loadTags() async {
    _tags = await _api.getTags();
  }

  /// Re-fetch from the API after navigation; otherwise apply filters locally.
  Future<void> _loadConversations({bool fromRemote = false}) async {
    if (!mounted) return;
    if (_allConversations.isEmpty || fromRemote) {
      final all = await _api.getConversations();
      if (!mounted) return;
      final allTags = await _api.getAllConversationTags();
      if (!mounted) return;
      _allConversations = all
          .map((c) => _ConvWithTags(c, allTags[c.uuid] ?? <String>[]))
          .toList();
      await _loadTags();
      if (!mounted) return;
    }
    // Local filtering only
    final filtered = _allConversations.where((ct) {
      if (ct.conv.hidden && !_showHidden) return false;
      if (_pinnedOnly && !ct.conv.pinned) return false;
      if (_hideAi && ct.conv.isAiGenerated) return false;
      if (_hideArchived && ct.conv.archived) return false;
      if (_selectedTags.isNotEmpty &&
          !ct.tags.any((t) => _selectedTags.contains(t))) {
        return false;
      }
      return true;
    }).toList();
    final dateFormat = DateFormat.yMMMMEEEEd(AppLanguage.locale);
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
    // VPS setConversationTags already does get_or_create_tag internally, so just pass the name directly.
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
          title: Text(tr("Manage tags")),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: nameCtrl,
                        decoration: InputDecoration(
                          hintText: tr("New tag name"),
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    SizedBox(width: 8),
                    IconButton(
                      icon: Icon(Icons.add_circle),
                      onPressed: () async {
                        if (nameCtrl.text.trim().isNotEmpty) {
                          await _api.createTag(nameCtrl.text.trim());
                          nameCtrl.clear();
                          await _loadTags();
                          setDialogState(() {});
                        }
                      },
                    ),
                  ],
                ),
                SizedBox(height: 8),
                SizedBox(
                  height: 200,
                  child: ListView(
                    children: _tags.map((t) {
                      final name = t['name'] as String;
                      final id = t['id'] as String;
                      return ListTile(
                        title: Text(name),
                        trailing: IconButton(
                          icon: Icon(Icons.delete_outline, size: 18),
                          onPressed: () async {
                            await _api.deleteTag(id);
                            await _loadTags();
                            setDialogState(() {});
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
              onPressed: () => Navigator.pop(ctx),
              child: Text(tr("Close")),
            ),
          ],
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
          title: Text(tr("Edit")),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: titleCtrl,
                decoration: InputDecoration(labelText: tr("Title")),
              ),
              SizedBox(height: 8),
              TextField(
                controller: noteCtrl,
                decoration: InputDecoration(
                  labelText: tr("Notes"),
                  hintText: tr("For example: #important #todo"),
                ),
              ),
              SizedBox(height: 12),
              SwitchListTile(
                title: Text(tr("Pin to favorites")),
                value: pinned,
                onChanged: (v) => setDialogState(() => pinned = v),
              ),
              SwitchListTile(
                title: Text(tr("Hide")),
                value: hidden,
                onChanged: (v) => setDialogState(() => hidden = v),
              ),
              Text(tr("Tags"), style: TextStyle(fontWeight: FontWeight.bold)),
              SizedBox(height: 4),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: _tags.map((t) {
                  final name = t['name'] as String;
                  return FilterChip(
                    label: Text(name),
                    selected: selectedTags.contains(name),
                    onSelected: (val) => setDialogState(() {
                      if (val) {
                        selectedTags.add(name);
                      } else {
                        selectedTags.remove(name);
                      }
                    }),
                  );
                }).toList(),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(tr("Cancel")),
            ),
            TextButton(
              onPressed: () async {
                Navigator.pop(ctx);
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (c) => AlertDialog(
                    title: Text(tr("Confirm deletion")),
                    content: Text(
                      tr(
                        "Delete “{0}” and all its messages?\nThis cannot be undone.",
                        [conv.title],
                      ),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(c, false),
                        child: Text(tr("Cancel")),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(c, true),
                        child: Text(
                          tr("Delete"),
                          style: TextStyle(color: Colors.red),
                        ),
                      ),
                    ],
                  ),
                );
                if (confirmed == true) {
                  await _api.deleteConversation(conv.uuid);
                  _loadConversations(fromRemote: true);
                }
              },
              child: Text(tr("Delete"), style: TextStyle(color: Colors.red)),
            ),
            TextButton(
              onPressed: () async {
                final newTitle = titleCtrl.text.trim().isEmpty
                    ? conv.title
                    : titleCtrl.text.trim();
                final newNote = noteCtrl.text.trim().isEmpty
                    ? null
                    : noteCtrl.text.trim();
                Navigator.pop(ctx);
                await _api.updateConversation(
                  Conversation(
                    uuid: conv.uuid,
                    title: newTitle,
                    summary: conv.summary,
                    userNote: newNote,
                    forkedFrom: conv.forkedFrom,
                    pinned: pinned,
                    hidden: hidden,
                    createdAt: conv.createdAt,
                    lastActiveAt: conv.lastActiveAt,
                    lastArchivedAt: conv.lastArchivedAt,
                  ),
                );
                await _applyTags(conv.uuid, selectedTags);
                _loadConversations(fromRemote: true);
              },
              child: Text(tr("Save")),
            ),
          ],
        ),
      ),
    );
  }

  // ============ Timeline ============

  List<Widget> _buildTimeline() {
    final widgets = <Widget>[];
    for (final date in _grouped.keys) {
      widgets.add(
        Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text(
            date,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.bold,
              color: Colors.teal,
            ),
          ),
        ),
      );
      for (final ct in _grouped[date]!) {
        final selected = _selectedConvIds.contains(ct.conv.uuid);
        widgets.add(
          ListTile(
            leading: _selectionMode
                ? Checkbox(
                    value: selected,
                    onChanged: (_) => _toggleSelection(ct.conv.uuid),
                  )
                : null,
            title: Row(
              children: [
                if (ct.conv.pinned)
                  Icon(Icons.star, size: 16, color: Colors.amber),
                if (ct.conv.hidden)
                  Icon(Icons.visibility_off, size: 16, color: Colors.grey),
                if (ct.conv.isAiGenerated)
                  Icon(Icons.smart_toy, size: 16, color: Colors.teal),
                if (ct.conv.archived)
                  Icon(Icons.archive, size: 16, color: Colors.brown),
                SizedBox(width: 4),
                Expanded(
                  child: Text(
                    ct.conv.title,
                    style: TextStyle(
                      color: ct.conv.hidden ? Colors.grey : null,
                    ),
                  ),
                ),
              ],
            ),
            subtitle: Text(ct.conv.summary ?? ''),
            trailing: _selectionMode
                ? null
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (ct.tags.isNotEmpty)
                        ...ct.tags
                            .take(3)
                            .map(
                              (t) => Padding(
                                padding: EdgeInsets.only(right: 4),
                                child: Chip(
                                  label: Text(t, style: TextStyle(fontSize: 9)),
                                  materialTapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                ),
                              ),
                            ),
                      if (ct.conv.userNote != null &&
                          ct.conv.userNote!.isNotEmpty)
                        Tooltip(
                          message: ct.conv.userNote!,
                          child: Icon(
                            Icons.push_pin,
                            size: 16,
                            color: Colors.orange.shade400,
                          ),
                        ),
                      Icon(Icons.chevron_right),
                    ],
                  ),
            onTap: _selectionMode
                ? () => _toggleSelection(ct.conv.uuid)
                : () async {
                    await Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => ChatPage(conversationId: ct.conv.uuid),
                      ),
                    );
                    _loadConversations(fromRemote: true);
                  },
            onLongPress: _selectionMode ? null : () => _showEditDialog(ct),
          ),
        );
        widgets.add(Divider(indent: 16));
      }
    }
    return widgets;
  }

  // ============ Build ============

  // ============ Batch selection ============

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
      await _api.updateConversation(
        Conversation(
          uuid: id,
          title: conv.title,
          summary: conv.summary,
          userNote: conv.userNote,
          forkedFrom: conv.forkedFrom,
          pinned: true,
          hidden: conv.hidden,
          createdAt: conv.createdAt,
          lastActiveAt: conv.lastActiveAt,
          lastArchivedAt: conv.lastArchivedAt,
        ),
      );
    }
    _exitSelectionMode();
    _loadConversations(fromRemote: true);
  }

  Future<void> _batchHide() async {
    final ids = Set<String>.from(_selectedConvIds);
    for (final id in ids) {
      final conv = _allConversations.firstWhere((c) => c.conv.uuid == id).conv;
      await _api.updateConversation(
        Conversation(
          uuid: id,
          title: conv.title,
          summary: conv.summary,
          userNote: conv.userNote,
          forkedFrom: conv.forkedFrom,
          pinned: conv.pinned,
          hidden: true,
          createdAt: conv.createdAt,
          lastActiveAt: conv.lastActiveAt,
          lastArchivedAt: conv.lastArchivedAt,
        ),
      );
    }
    _exitSelectionMode();
    _loadConversations(fromRemote: true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: _selectionMode
            ? Text(tr("{0} selected", [_selectedConvIds.length]))
            : Text(
                ApiService.account == 'demo'
                    ? tr("DailyNote · Public demo")
                    : tr("DailyNote · Personal"),
              ),
        leading: _selectionMode
            ? IconButton(icon: Icon(Icons.close), onPressed: _exitSelectionMode)
            : null,
        actions: _selectionMode
            ? [
                IconButton(
                  icon: Icon(Icons.select_all),
                  tooltip: tr("Select all"),
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
                  icon: Icon(Icons.switch_account_outlined),
                  tooltip: tr("Switch account"),
                  onPressed: () => _api.logout(),
                ),
                IconButton(
                  icon: Icon(_pinnedOnly ? Icons.star : Icons.star_border),
                  tooltip: _pinnedOnly ? tr("Show all") : tr("Favorites only"),
                  onPressed: () {
                    setState(() => _pinnedOnly = !_pinnedOnly);
                    _loadConversations(fromRemote: false);
                  },
                ),
                IconButton(
                  icon: Icon(
                    _showHidden ? Icons.visibility : Icons.visibility_off,
                    size: 20,
                  ),
                  tooltip: _showHidden
                      ? tr("Hide hidden entries")
                      : tr("Show all"),
                  onPressed: () {
                    setState(() => _showHidden = !_showHidden);
                    _loadConversations(fromRemote: false);
                  },
                ),
                IconButton(
                  icon: Icon(
                    _hideAi ? Icons.travel_explore : Icons.travel_explore,
                    color: _hideAi ? null : Colors.orange,
                  ),
                  tooltip: _hideAi
                      ? tr("Show AI discoveries")
                      : tr("Hide AI discoveries"),
                  onPressed: () {
                    setState(() => _hideAi = !_hideAi);
                    _loadConversations(fromRemote: false);
                  },
                ),
                IconButton(
                  icon: Icon(
                    _hideArchived ? Icons.archive_outlined : Icons.archive,
                    color: _hideArchived ? null : Colors.brown,
                  ),
                  tooltip: _hideArchived
                      ? tr("Show archived entries")
                      : tr("Hide archived entries"),
                  onPressed: () {
                    setState(() => _hideArchived = !_hideArchived);
                    _loadConversations(fromRemote: false);
                  },
                ),
                IconButton(
                  icon: Icon(Icons.label_outline),
                  tooltip: tr("Manage tags"),
                  onPressed: _showTagManager,
                ),
                IconButton(
                  icon: Icon(Icons.psychology_outlined),
                  tooltip: tr("Memories"),
                  onPressed: () async {
                    await Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => MemoriesPage()),
                    );
                    _loadConversations(fromRemote: true);
                  },
                ),
                IconButton(
                  icon: Icon(Icons.auto_awesome, size: 20),
                  tooltip: 'AI Soul',
                  onPressed: () async {
                    await Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => SoulPage()),
                    );
                  },
                ),
                IconButton(
                  icon: Icon(Icons.checklist, size: 20),
                  tooltip: tr("Select entries"),
                  onPressed: () => setState(() => _selectionMode = true),
                ),
              ],
      ),
      body: Column(
        children: [
          if (_tags.isNotEmpty)
            SizedBox(
              height: 44,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: EdgeInsets.symmetric(horizontal: 8),
                children: _tags.map((t) {
                  final name = t['name'] as String;
                  final selected = _selectedTags.contains(name);
                  return Padding(
                    padding: EdgeInsets.symmetric(horizontal: 4),
                    child: FilterChip(
                      label: Text(name),
                      selected: selected,
                      onSelected: (v) {
                        setState(() {
                          if (v) {
                            _selectedTags.add(name);
                          } else {
                            _selectedTags.remove(name);
                          }
                        });
                        _loadConversations(fromRemote: false); // Local filter
                      },
                    ),
                  );
                }).toList(),
              ),
            ),
          Expanded(
            child: _loading
                ? Center(child: CircularProgressIndicator())
                : _loadFailed
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(tr("Unable to connect. Please try again later.")),
                        SizedBox(height: 12),
                        FilledButton(
                          onPressed: _init,
                          child: Text(tr("Retry")),
                        ),
                      ],
                    ),
                  )
                : _grouped.isEmpty
                ? Center(child: Text(tr("No diary entries yet")))
                : ListView(children: _buildTimeline()),
          ),
        ],
      ),
      floatingActionButton: _selectionMode
          ? null
          : FloatingActionButton(
              onPressed: () async {
                await Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => ChatPage()),
                );
                _loadConversations();
              },
              child: Icon(Icons.add),
            ),
      bottomNavigationBar: _selectionMode && _selectedConvIds.isNotEmpty
          ? BottomAppBar(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  IconButton(
                    icon: Icon(Icons.delete, color: Colors.red),
                    tooltip: tr("Delete"),
                    onPressed: _batchDelete,
                  ),
                  IconButton(
                    icon: Icon(Icons.star, color: Colors.amber),
                    tooltip: tr("Favorite"),
                    onPressed: _batchPin,
                  ),
                  IconButton(
                    icon: Icon(Icons.visibility_off),
                    tooltip: tr("Hide"),
                    onPressed: _batchHide,
                  ),
                ],
              ),
            )
          : null,
    );
  }
}
