import '../services/l10n.dart';
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
    if (!mounted) return;
    _controller.text = content;
    setState(() => _loading = false);
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    await _api.updateSoul(_controller.text);
    if (!mounted) return;
    setState(() {
      _saving = false;
      _dirty = false;
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr("Saved")), duration: Duration(seconds: 1)),
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
        title: Text('AI Soul'),
        actions: [
          if (_dirty)
            IconButton(
              icon: _saving
                  ? SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(Icons.save),
              onPressed: _saving ? null : _save,
            ),
        ],
      ),
      body: _loading
          ? Center(child: CircularProgressIndicator())
          : Padding(
              padding: EdgeInsets.all(12),
              child: TextField(
                controller: _controller,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                onChanged: (_) => setState(() => _dirty = true),
                decoration: InputDecoration(
                  hintText: tr("Write the AI's behavior guidelines…"),
                  border: OutlineInputBorder(),
                ),
                style: TextStyle(fontFamily: 'monospace', fontSize: 14),
              ),
            ),
    );
  }
}
