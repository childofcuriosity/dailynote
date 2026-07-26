import 'package:flutter/material.dart';
import '../services/database.dart';

class MemoriesPage extends StatefulWidget {
  const MemoriesPage({super.key});

  @override
  State<MemoriesPage> createState() => _MemoriesPageState();
}

class _MemoriesPageState extends State<MemoriesPage> {
  final _db = DatabaseService();
  List<Map<String, dynamic>> _memories = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final list = await _db.getAllMemories();
    setState(() {
      _memories = list;
      _loading = false;
    });
  }

  Future<void> _delete(int id) async {
    await _db.deleteMemory(id);
    _load();
  }

  Future<void> _edit(int id, String current) async {
    final controller = TextEditingController(text: current);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('编辑记忆'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(border: OutlineInputBorder()),
          maxLines: 3,
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text('保存')),
        ],
      ),
    );
    if (result != null && result.isNotEmpty && result != current) {
      await _db.updateMemory(id, result);
      _load();
      }
  }

  Future<void> _add() async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('添加记忆'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: '如：用户喜欢鲁迅的作品',
            border: OutlineInputBorder(),
          ),
          maxLines: 3,
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text('添加')),
        ],
      ),
    );
    if (result != null && result.isNotEmpty) {
      await _db.insertMemory(result);
      _load();
      }
  }

  String _formatTime(int ms) {
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('记忆管理')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _memories.isEmpty
              ? const Center(child: Text('还没有记忆，归档对话后 AI 会自动提取'))
              : ListView.builder(
                  itemCount: _memories.length,
                  itemBuilder: (context, index) {
                    final m = _memories[index];
                    return Dismissible(
                      key: Key('mem-${m['id']}'),
                      direction: DismissDirection.endToStart,
                      background: Container(
                        color: Colors.red,
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.only(right: 16),
                        child: const Icon(Icons.delete, color: Colors.white),
                      ),
                      onDismissed: (_) => _delete(m['id'] as int),
                      child: ListTile(
                        title: Text(m['content'] as String),
                        subtitle: Text(_formatTime(m['created_at'] as int)),
                        onTap: () => _edit(m['id'] as int, m['content'] as String),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline, size: 20),
                          onPressed: () => _delete(m['id'] as int),
                        ),
                      ),
                    );
                  },
                ),
      floatingActionButton: FloatingActionButton(
        onPressed: _add,
        child: const Icon(Icons.add),
      ),
    );
  }
}
