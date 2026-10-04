import '../services/l10n.dart';
import 'package:flutter/material.dart';
import '../services/api_service.dart';

class MemoriesPage extends StatefulWidget {
  const MemoriesPage({super.key});

  @override
  State<MemoriesPage> createState() => _MemoriesPageState();
}

class _MemoriesPageState extends State<MemoriesPage> {
  final _api = ApiService();
  List<Map<String, dynamic>> _memories = [];
  bool _loading = true;

  static Map<String, String> get _typeLabels => {
    'fact': tr("Fact"),
    'feedback': tr("Feedback"),
    'observation': tr("Observation"),
    'self_correction': tr("Self-correction"),
  };
  static final _typeColors = {
    'fact': Colors.blue,
    'feedback': Colors.orange,
    'observation': Colors.purple,
    'self_correction': Colors.red,
  };

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final list = await _api.getAllMemories();
    if (!mounted) return;
    setState(() {
      _memories = list;
      _loading = false;
    });
  }

  Future<void> _delete(String id) async {
    await _api.deleteMemory(id);
    _load();
  }

  Future<void> _edit(Map<String, dynamic> m) async {
    final contentCtrl = TextEditingController(
      text: m['content'] as String? ?? '',
    );
    final nameCtrl = TextEditingController(text: m['name'] as String? ?? '');
    final descCtrl = TextEditingController(
      text: m['description'] as String? ?? '',
    );
    var selectedType = (m['type'] as String?) ?? 'fact';

    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(tr("Edit memory")),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Type selection
                Text(tr("Type"), style: TextStyle(fontWeight: FontWeight.bold)),
                SizedBox(height: 4),
                Wrap(
                  spacing: 6,
                  children: _typeLabels.entries
                      .map(
                        (e) => ChoiceChip(
                          label: Text(e.value, style: TextStyle(fontSize: 12)),
                          selected: selectedType == e.key,
                          selectedColor: _typeColors[e.key]?.withValues(
                            alpha: 0.3,
                          ),
                          onSelected: (_) =>
                              setDialogState(() => selectedType = e.key),
                        ),
                      )
                      .toList(),
                ),
                SizedBox(height: 12),
                // Name
                TextField(
                  controller: nameCtrl,
                  decoration: InputDecoration(
                    labelText: tr("Name"),
                    hintText: tr("kebab-case, e.g. prefer-short-replies"),
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                SizedBox(height: 8),
                // Description
                TextField(
                  controller: descCtrl,
                  decoration: InputDecoration(
                    labelText: tr("One-line summary"),
                    hintText: tr("Used to find relevant memories"),
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                SizedBox(height: 8),
                // Content
                TextField(
                  controller: contentCtrl,
                  decoration: InputDecoration(
                    labelText: tr("Full content"),
                    border: OutlineInputBorder(),
                  ),
                  maxLines: 4,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(tr("Cancel")),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, {
                'content': contentCtrl.text.trim(),
                'name': nameCtrl.text.trim(),
                'description': descCtrl.text.trim(),
                'type': selectedType,
              }),
              child: Text(tr("Save")),
            ),
          ],
        ),
      ),
    );
    if (result != null && result['content']!.isNotEmpty) {
      await _api.updateMemory(
        m['id'] as String,
        result['content']!,
        name: result['name']!.isEmpty ? null : result['name'],
        description: result['description']!.isEmpty
            ? null
            : result['description'],
        type: result['type'],
      );
      _load();
    }
  }

  Future<void> _add() async {
    final contentCtrl = TextEditingController();
    final nameCtrl = TextEditingController();
    final descCtrl = TextEditingController();
    var selectedType = 'fact';

    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(tr("Add memory")),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(tr("Type"), style: TextStyle(fontWeight: FontWeight.bold)),
                SizedBox(height: 4),
                Wrap(
                  spacing: 6,
                  children: _typeLabels.entries
                      .map(
                        (e) => ChoiceChip(
                          label: Text(e.value, style: TextStyle(fontSize: 12)),
                          selected: selectedType == e.key,
                          selectedColor: _typeColors[e.key]?.withValues(
                            alpha: 0.3,
                          ),
                          onSelected: (_) =>
                              setDialogState(() => selectedType = e.key),
                        ),
                      )
                      .toList(),
                ),
                SizedBox(height: 12),
                TextField(
                  controller: nameCtrl,
                  decoration: InputDecoration(
                    labelText: tr("Name"),
                    hintText: 'kebab-case',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                SizedBox(height: 8),
                TextField(
                  controller: descCtrl,
                  decoration: InputDecoration(
                    labelText: tr("One-line summary"),
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                SizedBox(height: 8),
                TextField(
                  controller: contentCtrl,
                  decoration: InputDecoration(
                    labelText: tr("Full content"),
                    border: OutlineInputBorder(),
                  ),
                  maxLines: 4,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(tr("Cancel")),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, {
                'content': contentCtrl.text.trim(),
                'name': nameCtrl.text.trim(),
                'description': descCtrl.text.trim(),
                'type': selectedType,
              }),
              child: Text(tr("Add")),
            ),
          ],
        ),
      ),
    );
    if (result != null && result['content']!.isNotEmpty) {
      await _api.insertMemory(
        result['content']!,
        name: result['name']!.isEmpty ? null : result['name'],
        description: result['description']!.isEmpty
            ? null
            : result['description'],
        type: result['type'],
      );
      _load();
    }
  }

  String _formatTime(dynamic v) {
    if (v is int) {
      final dt = DateTime.fromMillisecondsSinceEpoch(v);
      return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
    }
    return '';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr("Memories"))),
      body: _loading
          ? Center(child: CircularProgressIndicator())
          : _memories.isEmpty
          ? Center(
              child: Text(
                tr(
                  "No memories yet. AI can extract them when you archive a conversation.",
                ),
              ),
            )
          : ListView.builder(
              itemCount: _memories.length,
              itemBuilder: (context, index) {
                final m = _memories[index];
                final type = (m['type'] as String?) ?? 'fact';
                final name = m['name'] as String? ?? '';
                final desc = m['description'] as String? ?? '';
                final content = m['content'] as String? ?? '';

                return Dismissible(
                  key: Key('mem-${m['id']}'),
                  direction: DismissDirection.endToStart,
                  background: Container(
                    color: Colors.red,
                    alignment: Alignment.centerRight,
                    padding: EdgeInsets.only(right: 16),
                    child: Icon(Icons.delete, color: Colors.white),
                  ),
                  onDismissed: (_) => _delete(m['id'] as String),
                  child: ListTile(
                    title: Row(
                      children: [
                        Container(
                          padding: EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: (_typeColors[type] ?? Colors.grey)
                                .withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            _typeLabels[type] ?? type,
                            style: TextStyle(
                              fontSize: 10,
                              color: _typeColors[type],
                            ),
                          ),
                        ),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            desc.isNotEmpty ? desc : content,
                            maxLines: 8,
                          ),
                        ),
                      ],
                    ),
                    subtitle: Padding(
                      padding: EdgeInsets.only(top: 4),
                      child: Text(
                        [
                          if (name.isNotEmpty) name,
                          _formatTime(m['created_at']),
                        ].join(' · '),
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.grey.shade600,
                        ),
                      ),
                    ),
                    onTap: () => _edit(m),
                  ),
                );
              },
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: _add,
        child: Icon(Icons.add),
      ),
    );
  }
}
