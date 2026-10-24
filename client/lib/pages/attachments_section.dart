/// The "Attachments" part of the page editor: images shown inline, other
/// files listed for download.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../db/attachments.dart';
import '../db/database.dart';
import '../files/browser_files.dart';

/// Lists and adds the attachments of one page.
class AttachmentsSection extends StatefulWidget {
  const AttachmentsSection({required this.db, required this.nodeId, super.key});

  final GikiDatabase db;

  /// The page, or null while it has never been saved: an attachment needs a
  /// page id to point at.
  final String? nodeId;

  @override
  State<AttachmentsSection> createState() => _AttachmentsSectionState();
}

class _AttachmentsSectionState extends State<AttachmentsSection> {
  late final AttachmentRepository _attachments =
      AttachmentRepository(widget.db);

  /// The page's attachments, re-read only when an attachment or blob changes,
  /// not on every rebuild.
  List<Attachment> _list = const [];

  /// Image bytes by hash. Kept across rebuilds on purpose: Image.memory
  /// treats every new Uint8List as a new image, so re-reading the bytes on
  /// each build would decode every picture again.
  final Map<String, Uint8List> _images = {};

  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _reload();
    widget.db.attachmentsRevision.addListener(_changed);
  }

  @override
  void didUpdateWidget(AttachmentsSection old) {
    super.didUpdateWidget(old);
    if (old.nodeId != widget.nodeId) {
      _reload();
    }
  }

  @override
  void dispose() {
    widget.db.attachmentsRevision.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) {
      setState(_reload);
    }
  }

  void _reload() {
    final nodeId = widget.nodeId;
    _list = nodeId == null ? const [] : _attachments.forNode(nodeId);
    for (final attachment in _list) {
      if (attachment.isImage &&
          attachment.hasBytes &&
          !_images.containsKey(attachment.sha256)) {
        final bytes = _attachments.bytes(attachment.sha256);
        if (bytes != null) {
          _images[attachment.sha256] = bytes;
        }
      }
    }
    // Bytes of files attached elsewhere are fetched only now that someone
    // is looking at them.
    widget.db.wantBlobs([
      for (final attachment in _list)
        if (!attachment.hasBytes) attachment.sha256,
    ]);
  }

  Future<void> _attach(String nodeId) async {
    setState(() => _busy = true);
    try {
      final picked = await pickFiles(maxBytes: maxAttachmentBytes);
      final refused = <String>[];
      for (final file in picked) {
        final bytes = file.bytes;
        if (bytes == null) {
          refused.add('${file.name} is ${formatSize(file.size)}; the limit is '
              '${formatSize(maxAttachmentBytes)}.');
          continue;
        }
        try {
          _attachments.add(
            nodeId: nodeId,
            filename: file.name,
            mimeType: guessMimeType(file.name, file.mimeType),
            bytes: bytes,
          );
        } on AttachmentException catch (e) {
          refused.add(e.message);
        }
      }
      await widget.db.flush();
      if (refused.isNotEmpty && mounted) {
        _snack(refused.join('\n'));
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  void _download(Attachment attachment) {
    final bytes = _attachments.bytes(attachment.sha256);
    if (bytes == null) {
      _snack('${attachment.filename} is still downloading.');
      return;
    }
    saveFile(bytes, attachment.filename);
  }

  Future<void> _remove(Attachment attachment) async {
    _attachments.delete(attachment.id);
    await widget.db.flush();
  }

  Future<void> _showImage(Attachment attachment, Uint8List bytes) async {
    await showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: InteractiveViewer(child: Image.memory(bytes)),
            ),
            OverflowBar(
              children: [
                TextButton(
                  onPressed: () => _download(attachment),
                  child: const Text('Download'),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Close'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final nodeId = widget.nodeId;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Attachments', style: Theme.of(context).textTheme.titleSmall),
        if (nodeId == null)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('Save the page to attach images and files.'),
          )
        else ...[
          for (final attachment in _list) _tile(attachment),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: OutlinedButton.icon(
              onPressed: _busy ? null : () => _attach(nodeId),
              icon: const Icon(Icons.attach_file),
              label: const Text('Attach files'),
            ),
          ),
        ],
      ],
    );
  }

  Widget _tile(Attachment attachment) {
    final remove = IconButton(
      tooltip: 'Remove ${attachment.filename}',
      icon: const Icon(Icons.close),
      onPressed: () => _remove(attachment),
    );
    final bytes = _images[attachment.sha256];
    if (attachment.isImage && bytes != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Flexible(
              child: Semantics(
                button: true,
                label: 'Image ${attachment.filename}',
                child: InkWell(
                  onTap: () => _showImage(attachment, bytes),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 240),
                    child: Image.memory(
                      bytes,
                      fit: BoxFit.contain,
                      semanticLabel: attachment.filename,
                      // Not every file named .png decodes; show it as a file.
                      errorBuilder: (_, __, ___) => Text(attachment.filename),
                    ),
                  ),
                ),
              ),
            ),
            remove,
          ],
        ),
      );
    }
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(attachment.isImage
          ? Icons.image_outlined
          : Icons.description_outlined),
      title: Text(attachment.filename),
      subtitle: Text(attachment.hasBytes
          ? formatSize(attachment.size)
          : '${formatSize(attachment.size)} -- downloading'),
      onTap: () => _download(attachment),
      trailing: remove,
    );
  }
}
