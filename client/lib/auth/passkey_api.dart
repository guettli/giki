/// HTTP client for giki's passkey endpoints.
///
/// Pure Dart on purpose: the browser plumbing lives in webauthn.dart, so the
/// request and response shapes can be tested without a browser.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

/// Ensures a base URL ends in a slash.
///
/// Without it `Uri.resolve('api/v1/...')` replaces the last path segment
/// instead of appending: `https://host/giki` + `api/v1/sync` becomes
/// `https://host/api/v1/sync`, which is a 404 that looks like a server bug.
Uri normalizeBaseUrl(Uri baseUrl) {
  if (baseUrl.path.endsWith('/')) {
    return baseUrl;
  }
  return baseUrl.replace(path: '${baseUrl.path}/');
}

/// A WebAuthn ceremony the server has started.
class Ceremony {
  const Ceremony({required this.id, required this.options});

  /// The opaque handle to send back when finishing. Single-use.
  final String id;

  /// The `publicKey` options, with binary fields still base64url encoded.
  final Map<String, Object?> options;
}

/// A session the server issued after a successful ceremony.
class PasskeySession {
  const PasskeySession({
    required this.token,
    required this.userId,
    required this.expiresAt,
    required this.passkeyId,
  });

  /// The bearer token to use for sync. Shown exactly once.
  final String token;
  final String userId;
  final String expiresAt;
  final String passkeyId;
}

/// One registered authenticator.
class PasskeyInfo {
  const PasskeyInfo({
    required this.id,
    required this.label,
    required this.createdAt,
    required this.lastUsedAt,
  });

  final String id;
  final String label;
  final String createdAt;
  final String lastUsedAt;
}

/// Raised when the server refuses a passkey request. The message is the
/// server's own, which is written to be shown to a person.
class PasskeyException implements Exception {
  PasskeyException(this.statusCode, this.message);

  final int statusCode;
  final String message;

  @override
  String toString() => message;
}

/// Talks to /api/v1/auth.
class PasskeyApi {
  PasskeyApi({required Uri baseUrl, http.Client? httpClient})
      : baseUrl = normalizeBaseUrl(baseUrl),
        _http = httpClient ?? http.Client();

  /// The server's base URL, always ending in a slash.
  final Uri baseUrl;
  final http.Client _http;

  /// Starts registering an authenticator.
  ///
  /// [authorization] is the registration token for a new account, or an
  /// existing session token when adding another key to one's own account.
  Future<Ceremony> beginRegistration({
    required String userId,
    required String displayName,
    required String authorization,
  }) async {
    final body =
        await _post('api/v1/auth/passkey/register/begin', authorization, {
      'user_id': userId,
      'display_name': displayName,
    });
    return _ceremony(body);
  }

  /// Finishes registration and returns the session it issued.
  Future<PasskeySession> finishRegistration({
    required String ceremonyId,
    required Map<String, Object?> credential,
    required String authorization,
    String label = '',
  }) async {
    final body =
        await _post('api/v1/auth/passkey/register/finish', authorization, {
      'ceremony_id': ceremonyId,
      'credential': credential,
      'label': label,
    });
    return _session(body);
  }

  /// Starts a usernameless login. Needs no authorization -- that is the point.
  Future<Ceremony> beginLogin() async {
    final body = await _post('api/v1/auth/passkey/login/begin', '', null);
    return _ceremony(body);
  }

  /// Finishes a login and returns the session it issued.
  Future<PasskeySession> finishLogin({
    required String ceremonyId,
    required Map<String, Object?> credential,
  }) async {
    final body = await _post('api/v1/auth/passkey/login/finish', '', {
      'ceremony_id': ceremonyId,
      'credential': credential,
    });
    return _session(body);
  }

  /// Returns the user a token belongs to, and how it authenticated.
  Future<Map<String, String>> whoami(String token) async {
    final response = await _http.get(
      baseUrl.resolve('api/v1/auth/whoami'),
      headers: {'Authorization': 'Bearer $token'},
    );
    final body = _decode(response);
    return {
      'user_id': (body['user_id'] as String?) ?? '',
      'method': (body['method'] as String?) ?? '',
    };
  }

  /// Lists the authenticators registered for the token's account.
  Future<List<PasskeyInfo>> listPasskeys(String token) async {
    final response = await _http.get(
      baseUrl.resolve('api/v1/auth/passkeys'),
      headers: {'Authorization': 'Bearer $token'},
    );
    final body = _decode(response);
    return [
      for (final entry in (body['passkeys'] as List<Object?>? ?? const []))
        if (entry is Map<String, Object?>)
          PasskeyInfo(
            id: (entry['id'] as String?) ?? '',
            label: (entry['label'] as String?) ?? '',
            createdAt: (entry['created_at'] as String?) ?? '',
            lastUsedAt: (entry['last_used_at'] as String?) ?? '',
          ),
    ];
  }

  /// Revokes the given session server-side.
  Future<void> logout(String token) async {
    final response = await _http.post(
      baseUrl.resolve('api/v1/auth/logout'),
      headers: {'Authorization': 'Bearer $token'},
    );
    if (response.statusCode != 204) {
      _decode(response); // throws with the server's message
    }
  }

  /// Releases the underlying HTTP client.
  void close() => _http.close();

  /// The underlying client, for the administration calls in the extension
  /// below. Not part of the ceremony API.
  http.Client get _httpClient => _http;

  Future<Map<String, Object?>> _post(
      String path, String authorization, Object? body) async {
    final response = await _http.post(
      baseUrl.resolve(path),
      headers: {
        'Content-Type': 'application/json',
        if (authorization.isNotEmpty) 'Authorization': 'Bearer $authorization',
      },
      body: body == null ? null : jsonEncode(body),
    );
    return _decode(response);
  }

  Map<String, Object?> _decode(http.Response response) {
    Map<String, Object?> body = const {};
    if (response.body.isNotEmpty) {
      try {
        final decoded = jsonDecode(response.body);
        if (decoded is Map<String, Object?>) {
          body = decoded;
        }
      } on FormatException {
        // A proxy's HTML error page, or a captive portal. Fall through to the
        // status-based message rather than throwing something the UI cannot
        // explain.
      }
    }
    if (response.statusCode >= 400) {
      final message = (body['error'] as String?) ??
          'request failed (${response.statusCode})';
      throw PasskeyException(response.statusCode, message);
    }
    return body;
  }

  Ceremony _ceremony(Map<String, Object?> body) {
    final options = body['options'];
    if (body['ceremony_id'] is! String || options is! Map<String, Object?>) {
      throw PasskeyException(500, 'the server returned an unusable ceremony');
    }
    return Ceremony(id: body['ceremony_id']! as String, options: options);
  }

  PasskeySession _session(Map<String, Object?> body) {
    if (body['token'] is! String) {
      throw PasskeyException(500, 'the server returned no session token');
    }
    return PasskeySession(
      token: body['token']! as String,
      userId: (body['user_id'] as String?) ?? '',
      expiresAt: (body['expires_at'] as String?) ?? '',
      passkeyId: (body['passkey_id'] as String?) ?? '',
    );
  }
}

/// Removing a passkey. Separate from the class above only because it is the
/// one call that is not part of a ceremony.
extension PasskeyAdministration on PasskeyApi {
  /// Removes one registered authenticator.
  Future<void> deletePasskey(String token, String passkeyId) async {
    final response = await _httpClient.delete(
      baseUrl.resolve('api/v1/auth/passkeys/$passkeyId'),
      headers: {'Authorization': 'Bearer $token'},
    );
    if (response.statusCode != 204) {
      Map<String, Object?> body = const {};
      if (response.body.isNotEmpty) {
        final decoded = jsonDecode(response.body);
        if (decoded is Map<String, Object?>) {
          body = decoded;
        }
      }
      throw PasskeyException(
        response.statusCode,
        (body['error'] as String?) ?? 'could not remove the passkey',
      );
    }
  }
}
