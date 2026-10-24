/// The browser half of attachments: choosing files and saving them.
///
/// Web-only, like database.dart and webauthn.dart, and kept as small for the
/// same reason: it cannot be unit-tested on the Dart VM.
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// A file the user chose.
class PickedFile {
  const PickedFile(
      {required this.name, required this.mimeType, required this.bytes});

  final String name;

  /// What the browser says the type is; empty when it does not know.
  final String mimeType;
  final Uint8List bytes;
}

/// Opens the browser's file chooser and reads what the user picked.
///
/// Completes with an empty list when the chooser is dismissed: browsers fire
/// `cancel` for that since 2023, and without it the future would never
/// complete.
Future<List<PickedFile>> pickFiles({String accept = ''}) async {
  final input = web.HTMLInputElement()
    ..type = 'file'
    ..multiple = true
    ..accept = accept;
  final chosen = Completer<web.FileList?>();
  input.onchange = ((web.Event _) => chosen.complete(input.files)).toJS;
  input.oncancel = ((web.Event _) => chosen.complete(null)).toJS;
  input.click();

  final files = await chosen.future;
  if (files == null) {
    return const [];
  }
  return [
    for (var i = 0; i < files.length; i++) await _read(files.item(i)!),
  ];
}

Future<PickedFile> _read(web.File file) async {
  final buffer = await file.arrayBuffer().toDart;
  return PickedFile(
    name: file.name,
    mimeType: file.type,
    bytes: buffer.toDart.asUint8List(),
  );
}

/// Hands [bytes] to the browser as a download called [filename].
void saveFile(Uint8List bytes, String filename, String mimeType) {
  final blob = web.Blob(
    [bytes.toJS].toJS,
    web.BlobPropertyBag(
        type: mimeType.isEmpty ? 'application/octet-stream' : mimeType),
  );
  final url = web.URL.createObjectURL(blob);
  web.HTMLAnchorElement()
    ..href = url
    ..download = filename
    ..click();
  // Revoking right away can cancel the download in some browsers; a minute
  // is long enough for any of them to have started it.
  Timer(const Duration(minutes: 1), () => web.URL.revokeObjectURL(url));
}
