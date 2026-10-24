import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../app_config.dart';

/// First launch on a build without the server address baked in.
class ServerSetupScreen extends StatefulWidget {
  const ServerSetupScreen({super.key, required this.onSaved});
  final VoidCallback onSaved;

  @override
  State<ServerSetupScreen> createState() => _ServerSetupScreenState();
}

class _ServerSetupScreenState extends State<ServerSetupScreen> {
  final _url = TextEditingController();
  final _key = TextEditingController();
  String? _error;

  Future<void> _save() async {
    final url = _url.text.trim();
    if (!url.startsWith('https://') || _key.text.trim().length < 20) {
      setState(() => _error = 'Paste the Project URL and the publishable (anon) key from Supabase.');
      return;
    }
    await AppConfig.save(url, _key.text);
    widget.onSaved();
  }

  @override
  Widget build(BuildContext context) => _Centered(children: [
        const Icon(Icons.graphic_eq_rounded, size: 56),
        const SizedBox(height: 12),
        Text('Connect to your library', textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 8),
        const Text('Find these in Supabase: Project Settings → API. You only do this once.', textAlign: TextAlign.center),
        const SizedBox(height: 24),
        TextField(controller: _url, decoration: const InputDecoration(labelText: 'Project URL', hintText: 'https://xxxx.supabase.co', border: OutlineInputBorder())),
        const SizedBox(height: 12),
        TextField(controller: _key, decoration: const InputDecoration(labelText: 'Publishable / anon key', border: OutlineInputBorder())),
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: const TextStyle(color: Colors.redAccent))),
        const SizedBox(height: 20),
        FilledButton(onPressed: _save, child: const Text('Continue')),
      ]);
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;

  Future<void> _signIn() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await Supabase.instance.client.auth.signInWithPassword(email: _email.text.trim(), password: _password.text);
    } on AuthException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = 'Could not reach the server. Check your internet.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => _Centered(children: [
        const Icon(Icons.graphic_eq_rounded, size: 56),
        const SizedBox(height: 12),
        Text('Vibe', textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        const Text('Sign in with the account the library owner made for you.', textAlign: TextAlign.center),
        const SizedBox(height: 24),
        TextField(
          controller: _email,
          keyboardType: TextInputType.emailAddress,
          autofillHints: const [AutofillHints.email],
          decoration: const InputDecoration(labelText: 'Email', border: OutlineInputBorder()),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _password,
          obscureText: true,
          autofillHints: const [AutofillHints.password],
          decoration: const InputDecoration(labelText: 'Password', border: OutlineInputBorder()),
          onSubmitted: (_) => _signIn(),
        ),
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: const TextStyle(color: Colors.redAccent))),
        const SizedBox(height: 20),
        FilledButton(onPressed: _busy ? null : _signIn, child: Text(_busy ? 'Signing in...' : 'Sign in')),
        if (!AppConfig.isBuiltIn)
          TextButton(
            onPressed: () async {
              await AppConfig.clear();
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Server settings cleared. Restart the app to enter new ones.')));
              }
            },
            child: const Text('Change server'),
          ),
      ]);
}

/// Asks for the name others see in rooms, once.
class NameScreen extends StatefulWidget {
  const NameScreen({super.key, required this.onDone});
  final VoidCallback onDone;

  @override
  State<NameScreen> createState() => _NameScreenState();
}

class _NameScreenState extends State<NameScreen> {
  final _name = TextEditingController();

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    await Supabase.instance.client.from('profiles').upsert({'display_name': name});
    widget.onDone();
  }

  @override
  Widget build(BuildContext context) => _Centered(children: [
        Text('What should friends call you?', style: Theme.of(context).textTheme.headlineSmall, textAlign: TextAlign.center),
        const SizedBox(height: 8),
        const Text('Shown to others in listening rooms.'),
        const SizedBox(height: 24),
        TextField(
          controller: _name,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Your name', border: OutlineInputBorder()),
          onSubmitted: (_) => _save(),
        ),
        const SizedBox(height: 20),
        FilledButton(onPressed: _save, child: const Text('Let\'s go')),
      ]);
}

class _Centered extends StatelessWidget {
  const _Centered({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
            ),
          ),
        ),
      );
}
