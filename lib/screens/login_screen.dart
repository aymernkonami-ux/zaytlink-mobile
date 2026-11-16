import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final TextEditingController _email = TextEditingController();
  final TextEditingController _password = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    final email = _email.text.trim();
    if (!email.contains('@') || _password.text.isEmpty) {
      setState(() => _error = 'Enter your email and password.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await Supabase.instance.client.auth.signInWithPassword(email: email, password: _password.text);
    } on AuthException catch (e) {
      _error = e.message;
    } catch (_) {
      _error = 'Could not reach the server. Check your connection.';
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('ZAYTLINK', textAlign: TextAlign.center, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600, letterSpacing: 5)),
                  const SizedBox(height: 6),
                  const Text('Companion app. Sign in with your ZAYTLINK account.', textAlign: TextAlign.center, style: TextStyle(color: Color(0xFF91A49A))),
                  const SizedBox(height: 24),
                  if (_error != null)
                    Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(_error!, style: const TextStyle(color: Color(0xFFE35D5D)))),
                  TextField(controller: _email, keyboardType: TextInputType.emailAddress, decoration: const InputDecoration(labelText: 'Email', border: OutlineInputBorder())),
                  const SizedBox(height: 12),
                  TextField(controller: _password, obscureText: true, decoration: const InputDecoration(labelText: 'Password', border: OutlineInputBorder())),
                  const SizedBox(height: 16),
                  FilledButton(onPressed: _busy ? null : _signIn, child: Text(_busy ? 'Signing in...' : 'Sign in')),
                  const SizedBox(height: 12),
                  const Text('No account yet? Create one on the ZAYTLINK website first.', textAlign: TextAlign.center, style: TextStyle(color: Color(0xFF91A49A), fontSize: 12)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
