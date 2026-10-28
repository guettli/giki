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
import '../sync/serving_origin.dart';

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
  late final TextEditingController _url = TextEditingController(
      text: widget.db.meta(MetaKeys.serverUrl) ?? servingOrigin(Uri.base));
  late final TextEditingController _user =
      TextEditingController(text: widget.db.meta(MetaKeys.userId) ?? '');
  // A second controller for the Advanced section: both text fields are built
  // at once (an ExpansionTile builds its children even while collapsed), and
  // sharing one controller shares its selection and focus.
  late final TextEditingController _advancedUser =
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
    _advancedUser.dispose();
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
          await _storeSession(session);
          if (mounted) {
            setState(() => _status = 'Signed in as ${session.userId}.');
          }
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
          await _storeSession(session);
          _registerToken.clear();
          if (mounted) {
            setState(() => _status =
                'Passkey registered. Signed in as ${session.userId}.');
          }
          await _refreshPasskeys();
        } finally {
          api.close();
        }
      });

  Future<void> _signOut() => _guard(() async {
        final token = widget.db.meta(MetaKeys.token) ?? '';

        // Local first, and unconditionally. Pressing "Sign out" must not leave
        // the device signed in because the URL is blank or the server is
        // unreachable -- a silent, surprising outcome.
        await _clearSession();
        if (mounted) {
          setState(() {
            _passkeys = const [];
            _status = 'Signed out. Your pages stay on this device.';
          });
        }

        // Then tell the server, best effort: that is what stops the session
        // being usable elsewhere.
        final uri = _serverUri;
        if (token.isEmpty || uri == null) {
          return;
        }
        final api = PasskeyApi(baseUrl: uri);
        try {
          await api.logout(token);
        } on Object {
          if (mounted) {
            setState(() => _status =
                'Signed out on this device. The server could not be reached, '
                    'so its session expires on its own.');
          }
        } finally {
          api.close();
        }
      });

  /// Saves the operator settings: a static token, the user id, the URL.
  ///
  /// Replacing a passkey session with a static token revokes the session
  /// first, or it would keep working for weeks with no way for the user to
  /// reach it.
  Future<void> _saveAdvanced() => _guard(() async {
        final uri = _serverUri;
        final previous = widget.db.meta(MetaKeys.token) ?? '';
        final replacement = _staticToken.text.trim();

        if (replacement.isNotEmpty &&
            previous.isNotEmpty &&
            previous != replacement &&
            uri != null) {
          final api = PasskeyApi(baseUrl: uri);
          try {
            await api.logout(previous);
          } on Object {
            // An unreachable server, or a token that was never a session:
            // neither should block saving.
          } finally {
            api.close();
          }
        }

        if (replacement.isNotEmpty) {
          widget.db.setMeta(MetaKeys.token, replacement);
          widget.db.setMeta(MetaKeys.passkeyId, '');
        }
        widget.db.setMeta(MetaKeys.userId, _advancedUser.text.trim());
        if (uri != null) {
          widget.db.setMeta(MetaKeys.serverUrl, uri.toString());
        }
        await widget.db.flush();
        if (mounted) {
          setState(() => _status = 'Saved.');
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

  /// Persists a freshly issued session.
  ///
  /// The flush matters: on the IndexedDB file system -- which is the path in
  /// use until the database moves into a worker -- writes stay in memory until
  /// something flushes them. Without this, signing in survives only until the
  /// first successful background sync, and signing out would not survive a
  /// reload at all.
  Future<void> _storeSession(PasskeySession session) async {
    widget.db.setMeta(MetaKeys.token, session.token);
    widget.db.setMeta(MetaKeys.userId, session.userId);
    widget.db.setMeta(MetaKeys.passkeyId, session.passkeyId);
    await widget.db.flush();
    if (mounted) {
      _user.text = session.userId;
      _advancedUser.text = session.userId;
    }
  }

  /// Clears the local session. Deliberately independent of the server: a
  /// sign-out must work offline, and with a server URL that does not parse.
  Future<void> _clearSession() async {
    widget.db.setMeta(MetaKeys.token, '');
    widget.db.setMeta(MetaKeys.passkeyId, '');
    await widget.db.flush();
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

          // The server revokes the sessions a removed passkey issued, which
          // includes this one if the user removed the key they signed in with.
          // Keeping the dead token would leave the page claiming to be signed
          // in while every request 401s.
          if (passkey.id == (widget.db.meta(MetaKeys.passkeyId) ?? '')) {
            await _clearSession();
            if (mounted) {
              setState(() {
                _passkeys = const [];
                _status = 'Removed ${_name(passkey)}. That was this device\'s '
                    'passkey, so you are signed out here.';
              });
            }
            return;
          }
          if (mounted) {
            setState(() => _status = 'Removed ${_name(passkey)}.');
          }
          await _refreshPasskeys();
        } finally {
          api.close();
        }
      });

  String _name(PasskeyInfo passkey) =>
      passkey.label.isEmpty ? 'that passkey' : passkey.label;

  @override
  Widget build(BuildContext context) {
    final signedIn = (widget.db.meta(MetaKeys.token) ?? '').isNotEmpty;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Semantics(
              textField: true,
              label: 'Server URL',
              child: TextField(
                controller: _url,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: 'Server URL',
                  hintText: 'https://giki.example.org',
                  helperText:
                      'Without a server, giki works offline on this device alone.',
                ),
              )),
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
                Semantics(
                    textField: true,
                    label: 'User id',
                    child: TextField(
                      controller: _user,
                      decoration: const InputDecoration(
                        labelText: 'User id',
                        helperText: 'Recorded as the author of your changes.',
                      ),
                    )),
                const SizedBox(height: 8),
                Semantics(
                    textField: true,
                    label: 'Display name',
                    child: TextField(
                      controller: _displayName,
                      decoration:
                          const InputDecoration(labelText: 'Display name'),
                    )),
                const SizedBox(height: 8),
                Semantics(
                    textField: true,
                    label: 'Registration token',
                    child: TextField(
                      controller: _registerToken,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'Registration token',
                        helperText: 'Needed once, for a new account.',
                      ),
                    )),
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
              Semantics(
                  textField: true,
                  label: 'Static bearer token',
                  child: TextField(
                    controller: _staticToken,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'Static bearer token',
                      helperText:
                          'From the server\'s -tokens flag. Overwrites the passkey session.',
                    ),
                  )),
              const SizedBox(height: 8),
              Semantics(
                  textField: true,
                  label: 'User id',
                  child: TextField(
                    controller: _advancedUser,
                    decoration: const InputDecoration(labelText: 'User id'),
                  )),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: _busy ? null : _saveAdvanced,
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
