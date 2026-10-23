/// Server settings and passkey sign-in.
///
/// Everything here is stored in sync_meta, which is local-only: the server
/// never learns what this device calls itself, and these values never travel
/// through the sync protocol.
library;

import 'package:flutter/material.dart';

import '../auth/passkey_api.dart';
import '../auth/webauthn.dart';
import '../db/database.dart';

/// Lets the user point this device at a giki server and sign in with a
/// passkey.
class SettingsPage extends StatefulWidget {
  const SettingsPage({required this.db, super.key});

  /// The local database.
  final GikiDatabase db;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _url =
      TextEditingController(text: widget.db.meta(MetaKeys.serverUrl) ?? '');
  late final TextEditingController _user =
      TextEditingController(text: widget.db.meta(MetaKeys.userId) ?? '');
  final TextEditingController _displayName = TextEditingController();
  final TextEditingController _registerToken = TextEditingController();
  final TextEditingController _staticToken = TextEditingController();

  String _status = '';
  bool _busy = false;
  bool _showAdvanced = false;
  List<PasskeyInfo> _passkeys = const [];

  @override
  void initState() {
    super.initState();
    if ((widget.db.meta(MetaKeys.token) ?? '').isNotEmpty) {
      // Fire and forget: the page is useful before this answers.
      _refreshPasskeys();
    }
  }

  @override
  void dispose() {
    _url.dispose();
    _user.dispose();
    _displayName.dispose();
    _registerToken.dispose();
    _staticToken.dispose();
    super.dispose();
  }

  /// The configured server, or null when the URL is missing or unusable.
  Uri? get _serverUri {
    final text = _url.text.trim();
    if (text.isEmpty) {
      return null;
    }
    final uri = Uri.tryParse(text);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      return null;
    }
    return uri;
  }

  PasskeyApi? _api() {
    final uri = _serverUri;
    if (uri == null) {
      setState(() => _status =
          'Enter the server URL first, e.g. https://giki.example.org');
      return null;
    }
    widget.db.setMeta(MetaKeys.serverUrl, uri.toString());
    return PasskeyApi(baseUrl: uri);
  }

  /// Runs [action] with the busy flag set, turning failures into a status line
  /// rather than an unhandled exception in a button callback.
  Future<void> _guard(Future<void> Function() action) async {
    if (_busy) {
      return;
    }
    setState(() => _busy = true);
    try {
      await action();
    } on WebAuthnException catch (error) {
      if (mounted) {
        setState(
            () => _status = error.cancelled ? 'Cancelled.' : error.message);
      }
    } on PasskeyException catch (error) {
      if (mounted) {
        setState(() => _status = error.message);
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() => _status = 'Could not reach the server: $error');
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _signIn() => _guard(() async {
        final api = _api();
        if (api == null) {
          return;
        }
        try {
          setState(() => _status = 'Waiting for your passkey...');
          final ceremony = await api.beginLogin();
          final credential = await getCredential(ceremony.options);
          final session = await api.finishLogin(
            ceremonyId: ceremony.id,
            credential: credential,
          );
          _storeSession(session);
          setState(() => _status = 'Signed in as ${session.userId}.');
          await _refreshPasskeys();
        } finally {
          api.close();
        }
      });

  Future<void> _register() => _guard(() async {
        final api = _api();
        if (api == null) {
          return;
        }
        try {
          final signedIn = widget.db.meta(MetaKeys.token) ?? '';
          final authorization =
              signedIn.isNotEmpty ? signedIn : _registerToken.text.trim();
          if (authorization.isEmpty) {
            setState(() => _status =
                'A registration token is needed for a new account. Ask the server\'s owner.');
            return;
          }
          final userId = signedIn.isNotEmpty
              ? (widget.db.meta(MetaKeys.userId) ?? '')
              : _user.text.trim();
          if (userId.isEmpty) {
            setState(() => _status = 'Choose a user id first.');
            return;
          }

          setState(() => _status = 'Waiting for your passkey...');
          final ceremony = await api.beginRegistration(
            userId: userId,
            displayName: _displayName.text.trim(),
            authorization: authorization,
          );
          final credential = await createCredential(ceremony.options);
          final session = await api.finishRegistration(
            ceremonyId: ceremony.id,
            credential: credential,
            authorization: authorization,
            label: _deviceLabel(),
          );
          _storeSession(session);
          _registerToken.clear();
          setState(() =>
              _status = 'Passkey registered. Signed in as ${session.userId}.');
          await _refreshPasskeys();
        } finally {
          api.close();
        }
      });

  Future<void> _signOut() => _guard(() async {
        final token = widget.db.meta(MetaKeys.token) ?? '';
        final api = _api();
        if (api == null) {
          return;
        }
        try {
          if (token.isNotEmpty) {
            // Best effort: the session is useless locally either way, and a
            // server that cannot be reached must not block signing out.
            try {
              await api.logout(token);
            } on Object {
              // ignored on purpose; the local token is cleared below
            }
          }
          widget.db.setMeta(MetaKeys.token, '');
          setState(() {
            _passkeys = const [];
            _status = 'Signed out. Your pages stay on this device.';
          });
        } finally {
          api.close();
        }
      });

  Future<void> _refreshPasskeys() async {
    final token = widget.db.meta(MetaKeys.token) ?? '';
    final uri = _serverUri;
    if (token.isEmpty || uri == null) {
      return;
    }
    final api = PasskeyApi(baseUrl: uri);
    try {
      final passkeys = await api.listPasskeys(token);
      if (mounted) {
        setState(() => _passkeys = passkeys);
      }
    } on Object {
      // A static token has no passkeys, and an expired session will surface
      // on the next sync. Neither deserves an error here.
    } finally {
      api.close();
    }
  }

  void _storeSession(PasskeySession session) {
    widget.db.setMeta(MetaKeys.token, session.token);
    widget.db.setMeta(MetaKeys.userId, session.userId);
    _user.text = session.userId;
  }

  /// A label so a passkey list reads as devices rather than hashes.
  String _deviceLabel() {
    final label = _displayName.text.trim();
    return label.isEmpty ? 'this browser' : label;
  }

  Future<void> _removePasskey(PasskeyInfo passkey) => _guard(() async {
        final api = _api();
        if (api == null) {
          return;
        }
        try {
          await api.deletePasskey(
            widget.db.meta(MetaKeys.token) ?? '',
            passkey.id,
          );
          setState(() => _status = 'Removed ${passkey.label}.');
          await _refreshPasskeys();
        } finally {
          api.close();
        }
      });

  @override
  Widget build(BuildContext context) {
    final signedIn = (widget.db.meta(MetaKeys.token) ?? '').isNotEmpty;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _url,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: 'Server URL',
              hintText: 'https://giki.example.org',
              helperText:
                  'Without a server, giki works offline on this device alone.',
            ),
          ),
          const SizedBox(height: 24),

          Text('Passkey', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          if (!passkeysAvailable)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'This browser does not offer passkeys. They need https (or '
                'localhost during development).',
              ),
            )
          else if (signedIn) ...[
            Text('Signed in as ${widget.db.meta(MetaKeys.userId) ?? ''}'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _busy ? null : _register,
                  icon: const Icon(Icons.add),
                  label: const Text('Add another passkey'),
                ),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _signOut,
                  icon: const Icon(Icons.logout),
                  label: const Text('Sign out'),
                ),
              ],
            ),
            if (_passkeys.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text('Registered passkeys', style: theme.textTheme.titleSmall),
              for (final passkey in _passkeys)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.key),
                  title:
                      Text(passkey.label.isEmpty ? passkey.id : passkey.label),
                  subtitle: Text(passkey.lastUsedAt.isEmpty
                      ? 'added ${passkey.createdAt}'
                      : 'last used ${passkey.lastUsedAt}'),
                  trailing: IconButton(
                    tooltip: 'Remove',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: _busy ? null : () => _removePasskey(passkey),
                  ),
                ),
            ],
          ] else ...[
            FilledButton.icon(
              onPressed: _busy ? null : _signIn,
              icon: const Icon(Icons.key),
              label: const Text('Sign in with a passkey'),
            ),
            const SizedBox(height: 16),
            ExpansionTile(
              title: const Text('Register a new account'),
              childrenPadding: const EdgeInsets.symmetric(vertical: 8),
              children: [
                TextField(
                  controller: _user,
                  decoration: const InputDecoration(
                    labelText: 'User id',
                    helperText: 'Recorded as the author of your changes.',
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _displayName,
                  decoration: const InputDecoration(labelText: 'Display name'),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _registerToken,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Registration token',
                    helperText: 'Needed once, for a new account.',
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: _busy ? null : _register,
                  icon: const Icon(Icons.key),
                  label: const Text('Register a passkey'),
                ),
              ],
            ),
          ],

          const SizedBox(height: 16),
          if (_status.isNotEmpty)
            Card(
              color: theme.colorScheme.surfaceContainerHighest,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    if (_busy)
                      const Padding(
                        padding: EdgeInsets.only(right: 12),
                        child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    Expanded(child: Text(_status)),
                  ],
                ),
              ),
            ),

          const SizedBox(height: 24),
          // Static tokens are for operators and scripts; a person signing in
          // on their own device should never need this.
          ExpansionTile(
            title: const Text('Advanced'),
            initiallyExpanded: _showAdvanced,
            onExpansionChanged: (expanded) =>
                setState(() => _showAdvanced = expanded),
            childrenPadding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              TextField(
                controller: _staticToken,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Static bearer token',
                  helperText:
                      'From the server\'s -tokens flag. Overwrites the passkey session.',
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _user,
                decoration: const InputDecoration(labelText: 'User id'),
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () {
                  if (_staticToken.text.trim().isNotEmpty) {
                    widget.db.setMeta(MetaKeys.token, _staticToken.text.trim());
                  }
                  widget.db.setMeta(MetaKeys.userId, _user.text.trim());
                  final uri = _serverUri;
                  if (uri != null) {
                    widget.db.setMeta(MetaKeys.serverUrl, uri.toString());
                  }
                  setState(() => _status = 'Saved.');
                },
                child: const Text('Save'),
              ),
              const SizedBox(height: 16),
              Text('Device id: ${widget.db.deviceId}',
                  style: theme.textTheme.bodySmall),
              Text('Sync cursor: ${widget.db.cursor}',
                  style: theme.textTheme.bodySmall),
            ],
          ),
        ],
      ),
    );
  }
}
