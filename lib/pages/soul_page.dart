import 'package:flutter/material.dart';
import '../services/api_service.dart';

class SoulPage extends StatefulWidget {
  const SoulPage({super.key});

  @override
  State<SoulPage> createState() => _SoulPageState();
}

class _SoulPageState extends State<SoulPage> {
  final _api = ApiService();
  final _controller = TextEditingController();
  bool _loading = true;
  bool _saving = false;
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final content = await _api.getSoul();
    _controller.text = content;
    setState(() => _loading = false);
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    await _api.updateSoul(_controller.text);
    setState(() { _saving = false; _dirty = false; });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已保存'), duration: Duration(seconds: 1)),
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('AI Soul'),
        actions: [
          if (_dirty)
            IconButton(
              icon: _saving
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.save),
              onPressed: _saving ? null : _save,
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(12),
              child: TextField(
                controller: _controller,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                onChanged: (_) => setState(() => _dirty = true),
                decoration: const InputDecoration(
                  hintText: '写 AI 的行为准则...',
                  border: OutlineInputBorder(),
                ),
                style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
              ),
            ),
    );
  }
}
