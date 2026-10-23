/// The browser half of a passkey ceremony: `navigator.credentials`.
///
/// Web-only, like database.dart. Everything that can be expressed without the
/// browser lives in webauthn_json.dart, so this file stays small enough to
/// read in one go -- it cannot be unit-tested on the Dart VM, so size is the
/// only defence it has.
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'webauthn_json.dart';

/// Raised when the browser cannot or will not complete a ceremony.
class WebAuthnException implements Exception {
  WebAuthnException(this.message, {this.cancelled = false});

  final String message;

  /// True when the user dismissed the prompt (or it timed out). Not an error
  /// worth a red banner: they changed their mind.
  final bool cancelled;

  @override
  String toString() => message;
}

/// Whether this browser exposes WebAuthn at all. False on plain HTTP origins
/// other than localhost, because the API is restricted to secure contexts.
bool get passkeysAvailable =>
    (web.window as JSObject).has('PublicKeyCredential');

/// Runs a registration ceremony and returns the response JSON for the server.
Future<Map<String, Object?>> createCredential(
    Map<String, Object?> options) async {
  final credential = await _call('create', prepareCreationOptions(options));
  final response = credential.getProperty<JSObject>('response'.toJS);

  return registrationCredentialJson(
    id: credential.getProperty<JSString>('id'.toJS).toDart,
    rawId: _bytes(credential, 'rawId')!,
    clientDataJson: _bytes(response, 'clientDataJSON')!,
    attestationObject: _bytes(response, 'attestationObject')!,
    transports: _transports(response),
  );
}

/// Runs a login ceremony and returns the response JSON for the server.
Future<Map<String, Object?>> getCredential(Map<String, Object?> options) async {
  final credential = await _call('get', prepareRequestOptions(options));
  final response = credential.getProperty<JSObject>('response'.toJS);

  return assertionCredentialJson(
    id: credential.getProperty<JSString>('id'.toJS).toDart,
    rawId: _bytes(credential, 'rawId')!,
    clientDataJson: _bytes(response, 'clientDataJSON')!,
    authenticatorData: _bytes(response, 'authenticatorData')!,
    signature: _bytes(response, 'signature')!,
    userHandle: _bytes(response, 'userHandle'),
  );
}

/// Calls `navigator.credentials.<method>({publicKey: options})`.
Future<JSObject> _call(String method, Map<String, Object?> publicKey) async {
  if (!passkeysAvailable) {
    throw WebAuthnException(
      'This browser does not offer passkeys. They need a secure context: '
      'https, or localhost during development.',
    );
  }

  final request = JSObject()..setProperty('publicKey'.toJS, _toJs(publicKey)!);
  final credentials = (web.window.navigator as JSObject)
      .getProperty<JSObject>('credentials'.toJS);

  JSAny? result;
  try {
    result = await credentials
        .callMethod<JSPromise<JSAny?>>(method.toJS, request)
        .toDart;
  } on Object catch (error) {
    throw _translate(error);
  }
  if (result == null) {
    // The spec allows a null credential; in practice it means the user agent
    // gave up without raising.
    throw WebAuthnException('No passkey was returned.', cancelled: true);
  }
  return result as JSObject;
}

/// Turns a browser-side failure into something worth showing a person.
///
/// A rejected WebAuthn promise surfaces as a JS DOMException, whose `name` is
/// the only reliable thing to branch on -- the messages differ per browser.
WebAuthnException _translate(Object error) {
  final name = _jsProperty(error, 'name');
  final message = _jsProperty(error, 'message');

  switch (name) {
    case 'NotAllowedError':
      // Covers both "user dismissed the prompt" and "it timed out"; the
      // browser deliberately does not say which.
      return WebAuthnException('Passkey prompt dismissed.', cancelled: true);
    case 'InvalidStateError':
      return WebAuthnException(
          'This device already has a passkey for that account.');
    case 'SecurityError':
      return WebAuthnException(
        'The browser refused the passkey: the page origin does not match the '
        'server\'s passkey domain.',
      );
    case 'NotSupportedError':
      return WebAuthnException(
          'This device cannot create the kind of passkey the server asked for.');
    default:
      return WebAuthnException(
          message.isEmpty ? 'The passkey ceremony failed.' : message);
  }
}

/// Reads a string property off a thrown JavaScript error, if that is what it
/// is. The cast is guarded rather than tested: `is` on an interop type is not
/// reliable across compilers.
String _jsProperty(Object error, String key) {
  try {
    return (error as JSObject).getProperty<JSString?>(key.toJS)?.toDart ?? '';
  } on Object {
    return '';
  }
}

/// Reads an ArrayBuffer property, or null when absent.
Uint8List? _bytes(JSObject source, String key) {
  final value = source.getProperty<JSAny?>(key.toJS);
  if (value == null) {
    return null;
  }
  return (value as JSArrayBuffer).toDart.asUint8List();
}

List<String> _transports(JSObject response) {
  if (!response.has('getTransports')) {
    return const [];
  }
  final transports =
      response.callMethod<JSArray<JSString>?>('getTransports'.toJS);
  if (transports == null) {
    return const [];
  }
  return transports.toDart.map((value) => value.toDart).toList();
}

/// Converts a prepared options map to its JavaScript equivalent, leaving
/// [Uint8List] values as typed arrays -- which is what the WebAuthn API wants
/// wherever the JSON had base64url.
JSAny? _toJs(Object? value) {
  switch (value) {
    case null:
      return null;
    case final Uint8List bytes:
      return bytes.toJS;
    case final String text:
      return text.toJS;
    case final bool flag:
      return flag.toJS;
    case final num number:
      return number.toJS;
    case final List<Object?> list:
      return list.map(_toJs).toList().toJS;
    case final Map<Object?, Object?> map:
      final object = JSObject();
      for (final entry in map.entries) {
        final converted = _toJs(entry.value);
        if (converted != null) {
          object.setProperty((entry.key as String).toJS, converted);
        }
      }
      return object;
    default:
      throw WebAuthnException(
          'Cannot pass ${value.runtimeType} to the WebAuthn API.');
  }
}
