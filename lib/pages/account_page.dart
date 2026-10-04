import '../services/l10n.dart';
import 'package:flutter/material.dart';
import '../services/api_service.dart';

class AccountPage extends StatefulWidget {
  const AccountPage({super.key});

  @override
  State<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends State<AccountPage> {
  final _password = TextEditingController();
  bool _personal = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _enter() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ApiService().login(_personal ? 'personal' : 'demo', _password.text);
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error is StateError
              ? error.message.toString()
              : tr("Unable to connect. Please try again later."),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerLow,
      body: Center(
        child: SingleChildScrollView(
          child: Dialog(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: 420),
              child: Padding(
                padding: EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Icon(Icons.auto_stories_outlined, size: 40),
                    SizedBox(height: 16),
                    Text(
                      tr("Welcome to DailyNote"),
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    SizedBox(height: 8),
                    Text(
                      tr("Choose an account to get started"),
                      textAlign: TextAlign.center,
                    ),
                    SizedBox(height: 24),
                    SegmentedButton<bool>(
                      segments: [
                        ButtonSegment(
                          value: false,
                          label: Text(tr("Public demo")),
                        ),
                        ButtonSegment(
                          value: true,
                          label: Text(tr("Personal account")),
                        ),
                      ],
                      selected: {_personal},
                      onSelectionChanged: _busy
                          ? null
                          : (value) => setState(() {
                              _personal = value.single;
                              _error = null;
                              _password.clear();
                            }),
                    ),
                    SizedBox(height: 18),
                    Text(
                      _personal
                          ? tr(
                              "Enter your password to access your diary and memories.",
                            )
                          : tr(
                              "Explore sample entries and chat with AI. This demo is shared by all visitors. Please do not enter private information.",
                            ),
                    ),
                    if (_personal) ...[
                      SizedBox(height: 16),
                      TextField(
                        controller: _password,
                        obscureText: true,
                        enabled: !_busy,
                        decoration: InputDecoration(
                          labelText: tr("Password"),
                          border: OutlineInputBorder(),
                        ),
                        onSubmitted: (_) => _enter(),
                      ),
                    ],
                    if (_error != null) ...[
                      SizedBox(height: 12),
                      Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ],
                    SizedBox(height: 24),
                    FilledButton(
                      onPressed: _busy ? null : _enter,
                      child: Padding(
                        padding: EdgeInsets.all(10),
                        child: Text(
                          _busy ? tr("Signing in…") : tr("Enter DailyNote"),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
