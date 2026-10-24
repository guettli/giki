/// The "Attachments" part of the page editor: images shown inline, other
/// files listed for download.
library;

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
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    widget.db.attachmentsRevision.addListener(_changed);
  }

  @override
  void dispose() {
    widget.db.attachmentsRevision.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _attach(String nodeId) async {
    setState(() => _busy = true);
    try {
      final picked = await pickFiles();
      final refused = <String>[];
      for (final file in picked) {
        try {
          _attachments.add(
            nodeId: nodeId,
            filename: file.name,
            mimeType: guessMimeType(file.name, file.mimeType),
            bytes: file.bytes,
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
      _snack('${attachment.filename} has not been downloaded yet. '
          'It arrives with the next sync.');
      return;
    }
    saveFile(bytes, attachment.filename, attachment.mimeType);
  }

  Future<void> _remove(Attachment attachment) async {
    _attachments.delete(attachment.id);
    await widget.db.flush();
  }

  Future<void> _showImage(Attachment attachment) async {
    final bytes = _attachments.bytes(attachment.sha256);
    if (bytes == null) {
      return;
    }
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
    final attachments =
        nodeId == null ? const <Attachment>[] : _attachments.forNode(nodeId);

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
          for (final attachment in attachments) _tile(attachment),
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
    final bytes =
        attachment.isImage ? _attachments.bytes(attachment.sha256) : null;
    if (bytes != null) {
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
                  onTap: () => _showImage(attachment),
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
          : '${formatSize(attachment.size)} -- not downloaded yet'),
      onTap: () => _download(attachment),
      trailing: remove,
    );
  }

}
