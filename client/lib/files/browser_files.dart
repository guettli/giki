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
  const PickedFile({
    required this.name,
    required this.mimeType,
    required this.size,
    required this.bytes,
  });

  final String name;

  /// What the browser says the type is; empty when it does not know.
  final String mimeType;
  final int size;

  /// Null when the file is larger than the caller's limit: it was never read,
  /// so picking a 2 GB video costs nothing.
  final Uint8List? bytes;
}

/// Opens the browser's file chooser and reads what the user picked; files
/// over [maxBytes] come back unread.
///
/// Completes with an empty list when the chooser is dismissed: browsers fire
/// `cancel` for that since 2023, and without it the future would never
/// complete. The input is attached to the document while the chooser is open,
/// since a detached element can be collected before it reports anything.
Future<List<PickedFile>> pickFiles({required int maxBytes}) async {
  final input = web.HTMLInputElement()
    ..type = 'file'
    ..multiple = true
    ..style.display = 'none';
  final chosen = Completer<web.FileList?>();
  void finish(web.FileList? files) {
    if (!chosen.isCompleted) {
      chosen.complete(files);
    }
  }

  input.onchange = ((web.Event _) => finish(input.files)).toJS;
  input.oncancel = ((web.Event _) => finish(null)).toJS;
  web.document.body!.append(input);
  try {
    input.click();
    final files = await chosen.future;
    if (files == null) {
      return const [];
    }
    return [
      for (var i = 0; i < files.length; i++)
        await _read(files.item(i)!, maxBytes),
    ];
  } finally {
    input.remove();
  }
}

Future<PickedFile> _read(web.File file, int maxBytes) async {
  final tooLarge = file.size > maxBytes;
  return PickedFile(
    name: file.name,
    mimeType: file.type,
    size: file.size,
    bytes: tooLarge
        ? null
        : (await file.arrayBuffer().toDart).toDart.asUint8List(),
  );
}

/// Hands [bytes] to the browser as a download called [filename].
///
/// Always as application/octet-stream: the type in the attachment row came
/// from another device, and an opaque download is the one thing no type can
/// turn into a page.
void saveFile(Uint8List bytes, String filename) {
  final blob = web.Blob(
    [bytes.toJS].toJS,
    web.BlobPropertyBag(type: 'application/octet-stream'),
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
