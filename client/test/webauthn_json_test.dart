import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:giki/auth/webauthn_json.dart';

void main() {
  group('base64url', () {
    test('decodes what the server sends, padded or not', () {
      // go-webauthn emits unpadded base64url; other servers pad.
      expect(decodeBase64Url('AQID'), Uint8List.fromList([1, 2, 3]));
      expect(decodeBase64Url('AQI'), Uint8List.fromList([1, 2]));
      expect(decodeBase64Url('AQI='), Uint8List.fromList([1, 2]));
    });

    test('handles the url-safe alphabet, which plain base64 would reject', () {
      final bytes = Uint8List.fromList([251, 255, 190]);
      final encoded = encodeBase64Url(bytes);
      expect(encoded, isNot(contains('+')));
      expect(encoded, isNot(contains('/')));
      expect(encoded, isNot(contains('=')));
      expect(decodeBase64Url(encoded), bytes);
    });

    test('round trips a realistic 32-byte challenge', () {
      final challenge =
          Uint8List.fromList(List.generate(32, (i) => i * 7 % 256));
      expect(decodeBase64Url(encodeBase64Url(challenge)), challenge);
    });
  });

  group('prepareCreationOptions', () {
    Map<String, Object?> serverOptions() => {
          'challenge': encodeBase64Url(List.generate(32, (i) => i)),
          'rp': {'id': 'giki.example.org', 'name': 'giki'},
          'user': {
            'id': encodeBase64Url(List.generate(32, (i) => 255 - i)),
            'name': 'alice',
            'displayName': 'Alice',
          },
          'pubKeyCredParams': [
            {'type': 'public-key', 'alg': -7},
          ],
          'authenticatorSelection': {'residentKey': 'required'},
          'excludeCredentials': [
            {
              'type': 'public-key',
              'id': encodeBase64Url([1, 2, 3])
            },
          ],
        };

    test('turns every binary field into bytes', () {
      final prepared = prepareCreationOptions(serverOptions());

      expect(prepared['challenge'], isA<Uint8List>());
      expect((prepared['challenge']! as Uint8List).length, 32);
      final user = prepared['user']! as Map<String, Object?>;
      expect(user['id'], isA<Uint8List>());
      // Non-binary members are passed through untouched.
      expect(user['name'], 'alice');
      expect(prepared['rp'], serverOptions()['rp']);

      final exclude = prepared['excludeCredentials']! as List<Object?>;
      expect((exclude.single as Map)['id'], Uint8List.fromList([1, 2, 3]));
    });

    test('does not mutate the caller\'s JSON', () {
      final original = serverOptions();
      prepareCreationOptions(original);
      expect(original['challenge'], isA<String>());
      expect((original['user']! as Map)['id'], isA<String>());
    });

    test('drops an empty exclude list rather than sending one', () {
      final options = serverOptions()..remove('excludeCredentials');
      expect(prepareCreationOptions(options).containsKey('excludeCredentials'),
          isFalse);
    });

    test('fails loudly when the challenge is missing', () {
      final options = serverOptions()..remove('challenge');
      expect(() => prepareCreationOptions(options),
          throwsA(isA<FormatException>()));
    });
  });

  group('prepareRequestOptions', () {
    test('omits allowCredentials for a usernameless login', () {
      // An empty list and an absent one are not the same to every browser,
      // and a discoverable login wants it absent.
      final prepared = prepareRequestOptions({
        'challenge': encodeBase64Url([1, 2, 3, 4]),
        'rpId': 'giki.example.org',
        'allowCredentials': <Object?>[],
      });
      expect(prepared.containsKey('allowCredentials'), isFalse);
      expect(prepared['challenge'], Uint8List.fromList([1, 2, 3, 4]));
      expect(prepared['rpId'], 'giki.example.org');
    });

    test('decodes a credential filter when the server sends one', () {
      final prepared = prepareRequestOptions({
        'challenge': encodeBase64Url([9]),
        'allowCredentials': [
          {
            'type': 'public-key',
            'id': encodeBase64Url([7, 8])
          },
        ],
      });
      final allow = prepared['allowCredentials']! as List<Object?>;
      expect((allow.single as Map)['id'], Uint8List.fromList([7, 8]));
    });
  });

  group('credential JSON', () {
    test('encodes a registration response the way the server parses it', () {
      final json = registrationCredentialJson(
        id: 'credential-id',
        rawId: Uint8List.fromList([1, 2]),
        clientDataJson:
            Uint8List.fromList(utf8.encode('{"type":"webauthn.create"}')),
        attestationObject: Uint8List.fromList([3, 4]),
        transports: const ['internal', 'hybrid'],
      );

      expect(json['id'], 'credential-id');
      expect(json['type'], 'public-key');
      expect(json['rawId'], encodeBase64Url([1, 2]));
      final response = json['response']! as Map<String, Object?>;
      expect(
        utf8.decode(decodeBase64Url(response['clientDataJSON']! as String)),
        '{"type":"webauthn.create"}',
      );
      expect(response['attestationObject'], encodeBase64Url([3, 4]));
      expect(response['transports'], ['internal', 'hybrid']);
      // The server rejects unknown fields, so the shape must be exactly this.
      expect(json.keys.toSet(),
          {'id', 'rawId', 'type', 'response', 'clientExtensionResults'});
    });

    test('includes the user handle only when the authenticator gave one', () {
      final withHandle = assertionCredentialJson(
        id: 'x',
        rawId: Uint8List.fromList([1]),
        clientDataJson: Uint8List.fromList([2]),
        authenticatorData: Uint8List.fromList([3]),
        signature: Uint8List.fromList([4]),
        userHandle: Uint8List.fromList([5, 6]),
      );
      expect((withHandle['response']! as Map)['userHandle'],
          encodeBase64Url([5, 6]));

      // Omitted rather than empty: the server refuses a blank handle, and an
      // absent field makes that refusal readable.
      for (final handle in [null, Uint8List(0)]) {
        final without = assertionCredentialJson(
          id: 'x',
          rawId: Uint8List.fromList([1]),
          clientDataJson: Uint8List.fromList([2]),
          authenticatorData: Uint8List.fromList([3]),
          signature: Uint8List.fromList([4]),
          userHandle: handle,
        );
        expect(
            (without['response']! as Map).containsKey('userHandle'), isFalse);
      }
    });
  });
}
