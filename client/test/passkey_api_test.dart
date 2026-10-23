import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:giki/auth/passkey_api.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  final baseUrl = Uri.parse('https://giki.example.org');

  /// Records what the client sent, and replies with [body].
  ({PasskeyApi api, List<http.Request> sent}) apiReturning(
    String body, {
    int status = 200,
  }) {
    final sent = <http.Request>[];
    final client = MockClient((request) async {
      sent.add(request);
      return http.Response(body, status,
          headers: {'content-type': 'application/json'});
    });
    return (api: PasskeyApi(baseUrl: baseUrl, httpClient: client), sent: sent);
  }

  test('beginRegistration sends the account and the authorization', () async {
    final fixture = apiReturning(jsonEncode({
      'ceremony_id': 'ceremony-1',
      'options': {
        'challenge': 'AQID',
        'rp': {'id': 'giki.example.org'}
      },
    }));

    final ceremony = await fixture.api.beginRegistration(
      userId: 'alice',
      displayName: 'Alice',
      authorization: 'register-token',
    );

    expect(ceremony.id, 'ceremony-1');
    expect(ceremony.options['challenge'], 'AQID');

    final request = fixture.sent.single;
    expect(request.url.path, '/api/v1/auth/passkey/register/begin');
    expect(request.headers['Authorization'], 'Bearer register-token');
    expect(jsonDecode(request.body),
        {'user_id': 'alice', 'display_name': 'Alice'});
  });

  test('beginLogin sends no authorization: that is the point', () async {
    final fixture = apiReturning(jsonEncode({
      'ceremony_id': 'ceremony-2',
      'options': {'challenge': 'AQID'},
    }));

    await fixture.api.beginLogin();

    final request = fixture.sent.single;
    expect(request.headers.containsKey('Authorization'), isFalse);
    expect(request.url.path, '/api/v1/auth/passkey/login/begin');
  });

  test('finishLogin passes the credential through untouched', () async {
    final fixture = apiReturning(jsonEncode({
      'token': 'session-token',
      'user_id': 'alice',
      'expires_at': '2026-11-22T05:00:00.000Z',
      'passkey_id': 'cred-1',
    }));

    final credential = {
      'id': 'cred-1',
      'rawId': 'AQID',
      'type': 'public-key',
      'response': {
        'clientDataJSON': 'e30',
        'authenticatorData': 'AQ',
        'signature': 'Ag'
      },
      'clientExtensionResults': <String, Object?>{},
    };
    final session = await fixture.api.finishLogin(
      ceremonyId: 'ceremony-2',
      credential: credential,
    );

    expect(session.token, 'session-token');
    expect(session.userId, 'alice');
    expect(session.expiresAt, '2026-11-22T05:00:00.000Z');

    final body = jsonDecode(fixture.sent.single.body) as Map<String, Object?>;
    expect(body['ceremony_id'], 'ceremony-2');
    // Byte-for-byte: the server hands this to the WebAuthn library, so any
    // reshaping here would break verification.
    expect(body['credential'], credential);
  });

  test('surfaces the server\'s own message on failure', () async {
    final fixture = apiReturning(
      jsonEncode({'error': 'that passkey was not accepted'}),
      status: 401,
    );

    await expectLater(
      fixture.api.finishLogin(ceremonyId: 'c', credential: const {}),
      throwsA(isA<PasskeyException>()
          .having((e) => e.statusCode, 'statusCode', 401)
          .having(
              (e) => e.message, 'message', 'that passkey was not accepted')),
    );
  });

  test('reports a response that carries no token rather than returning empty',
      () async {
    final fixture = apiReturning(jsonEncode({'user_id': 'alice'}));

    await expectLater(
      fixture.api.finishLogin(ceremonyId: 'c', credential: const {}),
      throwsA(isA<PasskeyException>()),
    );
  });

  test('listPasskeys decodes the list', () async {
    final fixture = apiReturning(jsonEncode({
      'passkeys': [
        {
          'id': 'a',
          'label': 'laptop',
          'created_at': 'then',
          'last_used_at': 'now'
        },
        {'id': 'b', 'label': '', 'created_at': 'then', 'last_used_at': ''},
      ],
    }));

    final passkeys = await fixture.api.listPasskeys('session-token');

    expect(passkeys, hasLength(2));
    expect(passkeys.first.label, 'laptop');
    expect(passkeys.last.lastUsedAt, isEmpty);
    expect(
        fixture.sent.single.headers['Authorization'], 'Bearer session-token');
  });

  test('logout accepts an empty 204 body', () async {
    final sent = <http.Request>[];
    final client = MockClient((request) async {
      sent.add(request);
      return http.Response('', 204);
    });
    final api = PasskeyApi(baseUrl: baseUrl, httpClient: client);

    await api.logout('session-token');

    expect(sent.single.url.path, '/api/v1/auth/logout');
  });

  test('whoami reports the user and the method', () async {
    final fixture =
        apiReturning(jsonEncode({'user_id': 'alice', 'method': 'session'}));

    final who = await fixture.api.whoami('session-token');

    expect(who['user_id'], 'alice');
    expect(who['method'], 'session');
  });
}
