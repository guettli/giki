/// Conversions between the JSON a WebAuthn server speaks and the binary fields
/// the browser API expects.
///
/// The WebAuthn JS API takes and returns ArrayBuffers, while JSON carries
/// base64url strings. Translating between them is exactly the kind of code
/// that fails silently -- a wrong padding or a missed field produces
/// "verification failed" with no hint where -- so it lives here, as plain
/// Dart, with tests.
library;

import 'dart:convert';
import 'dart:typed_data';

/// Decodes a base64url string, with or without padding.
///
/// Servers differ: go-webauthn emits unpadded base64url, other
/// implementations pad. Accept both rather than make the caller care.
Uint8List decodeBase64Url(String value) {
  final normalized = value.replaceAll('-', '+').replaceAll('_', '/');
  final padded = normalized.padRight((normalized.length + 3) & ~3, '=');
  return base64.decode(padded);
}

/// Encodes bytes as unpadded base64url, which is what the server expects.
String encodeBase64Url(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

/// Turns the server's `publicKey` creation options into a map whose binary
/// members are [Uint8List], ready to hand to `navigator.credentials.create`.
///
/// Returns a copy: the caller's JSON is left alone.
Map<String, Object?> prepareCreationOptions(Map<String, Object?> options) {
  final prepared = Map<String, Object?>.of(options);

  prepared['challenge'] = _requireBinary(options, 'challenge');

  final user = options['user'];
  if (user is Map) {
    final preparedUser = Map<String, Object?>.of(user.cast<String, Object?>());
    preparedUser['id'] = _requireBinary(preparedUser, 'id');
    prepared['user'] = preparedUser;
  }

  prepared['excludeCredentials'] =
      _prepareDescriptors(options['excludeCredentials']);
  if ((prepared['excludeCredentials'] as List).isEmpty) {
    prepared.remove('excludeCredentials');
  }
  return prepared;
}

/// Turns the server's `publicKey` request options into a map ready for
/// `navigator.credentials.get`.
Map<String, Object?> prepareRequestOptions(Map<String, Object?> options) {
  final prepared = Map<String, Object?>.of(options);
  prepared['challenge'] = _requireBinary(options, 'challenge');
  prepared['allowCredentials'] =
      _prepareDescriptors(options['allowCredentials']);
  if ((prepared['allowCredentials'] as List).isEmpty) {
    // An empty list and an absent one mean different things to some browsers;
    // absent is what a usernameless login wants.
    prepared.remove('allowCredentials');
  }
  return prepared;
}

List<Map<String, Object?>> _prepareDescriptors(Object? raw) {
  if (raw is! List) {
    return const [];
  }
  return [
    for (final entry in raw)
      if (entry is Map)
        {
          ...entry.cast<String, Object?>(),
          'id': _requireBinary(entry.cast<String, Object?>(), 'id'),
        },
  ];
}

Uint8List _requireBinary(Map<String, Object?> source, String key) {
  final value = source[key];
  if (value is Uint8List) {
    return value;
  }
  if (value is String && value.isNotEmpty) {
    return decodeBase64Url(value);
  }
  throw FormatException(
      'WebAuthn options are missing "$key"', source.toString());
}

/// Builds the registration response JSON the server expects.
Map<String, Object?> registrationCredentialJson({
  required String id,
  required Uint8List rawId,
  required Uint8List clientDataJson,
  required Uint8List attestationObject,
  List<String> transports = const [],
}) {
  return {
    'id': id,
    'rawId': encodeBase64Url(rawId),
    'type': 'public-key',
    'response': {
      'clientDataJSON': encodeBase64Url(clientDataJson),
      'attestationObject': encodeBase64Url(attestationObject),
      if (transports.isNotEmpty) 'transports': transports,
    },
    'clientExtensionResults': <String, Object?>{},
  };
}

/// Builds the login response JSON the server expects.
///
/// `userHandle` is what makes a usernameless login possible: the server looks
/// the account up by it. It is omitted when the authenticator does not supply
/// one -- and a server that follows the spec will then refuse the login, which
/// is a clearer failure than sending an empty string.
Map<String, Object?> assertionCredentialJson({
  required String id,
  required Uint8List rawId,
  required Uint8List clientDataJson,
  required Uint8List authenticatorData,
  required Uint8List signature,
  Uint8List? userHandle,
}) {
  return {
    'id': id,
    'rawId': encodeBase64Url(rawId),
    'type': 'public-key',
    'response': {
      'clientDataJSON': encodeBase64Url(clientDataJson),
      'authenticatorData': encodeBase64Url(authenticatorData),
      'signature': encodeBase64Url(signature),
      if (userHandle != null && userHandle.isNotEmpty)
        'userHandle': encodeBase64Url(userHandle),
    },
    'clientExtensionResults': <String, Object?>{},
  };
}
