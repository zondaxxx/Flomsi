import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/models.dart';
import '../../platform.dart';
import '../../state/providers.dart';
import '../../theme/motion.dart';
import '../../theme/surfaces.dart';
import '../../theme/tokens.dart';

/// Glyph for a file by MIME type, falling back to the extension.
IconData iconForFile(String mime, String name) {
  final m = mime.toLowerCase();
  final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
  if (m.startsWith('image/')) return CupertinoIcons.photo;
  if (m.startsWith('video/')) return CupertinoIcons.film;
  if (m.startsWith('audio/')) return CupertinoIcons.music_note;
  if (m == 'message/rfc822' || ext == 'eml') return CupertinoIcons.envelope;
  if (m.contains('zip') ||
      m.contains('compressed') ||
      const {'zip', 'rar', '7z', 'gz', 'tar'}.contains(ext)) {
    return CupertinoIcons.archivebox;
  }
  if (m == 'text/calendar' || ext == 'ics') return CupertinoIcons.calendar;
  if (m == 'application/pdf' ||
      m.startsWith('text/') ||
      m.contains('document') ||
      m.contains('sheet') ||
      m.contains('presentation') ||
      m.contains('msword')) {
    return CupertinoIcons.doc_text;
  }
  return CupertinoIcons.doc;
}

String _reason(Object e) =>
    e.toString().replaceFirst(RegExp(r'^[\w ]*(Exception|Error): '), '');

/// The bordered 30 px row both chip kinds share: glyph, mono name, size, trailing slot.
class _ChipFrame extends StatelessWidget {
  const _ChipFrame({
    required this.icon,
    required this.name,
    required this.size,
    required this.hovered,
    this.busy = false,
    this.muted = false,
    this.trailing,
  });
  final IconData icon;
  final String name;
  final String size;
  final bool hovered;
  final bool busy;
  final bool muted;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    return AnimatedContainer(
      duration: Motion.of(context, Motion.fast),
      curve: Motion.curve,
      height: 30,
      padding: EdgeInsets.only(left: 10, right: trailing == null ? 10 : 3),
      decoration: BoxDecoration(
        color: hovered ? s.hover : null,
        border: Border.all(color: hovered ? s.fg3 : s.border),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 14,
            child: AnimatedSwitcher(
              duration: Motion.of(context, Motion.fast),
              child: busy
                  ? SizedBox(
                      key: const ValueKey('busy'),
                      width: 11,
                      height: 11,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.5,
                        color: s.blue,
                      ),
                    )
                  : Icon(
                      icon,
                      key: const ValueKey('icon'),
                      size: 13,
                      color: s.fg2,
                    ),
            ),
          ),
          const SizedBox(width: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 240),
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: mono(context, size: 12, color: muted ? s.fg2 : s.fg),
            ),
          ),
          const SizedBox(width: 8),
          Text(size, style: mono(context, size: 12, color: s.fg3)),
          ?trailing,
        ],
      ),
    );
  }
}

/// A received attachment. Click opens it with the system's app (desktop) or offers the
/// share sheet (phones); the arrow saves a copy to Downloads on desktop.
class AttachmentChip extends ConsumerStatefulWidget {
  const AttachmentChip(this.attachment, {super.key});
  final Attachment attachment;

  @override
  ConsumerState<AttachmentChip> createState() => _AttachmentChipState();
}

class _AttachmentChipState extends ConsumerState<AttachmentChip> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() job) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await job();
    } catch (e) {
      ref.read(noticeProvider.notifier).show(_reason(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _open() {
    final a = widget.attachment;
    final box = context.findRenderObject() as RenderBox?;
    final origin = box == null
        ? null
        : box.localToGlobal(Offset.zero) & box.size;
    return _run(() async {
      final path = await ref.read(repositoryProvider).openAttachment(a);
      if (kTouch) {
        await SharePlus.instance.share(
          ShareParams(
            files: [XFile(path, mimeType: a.mime)],
            sharePositionOrigin: origin,
          ),
        );
      } else if (!await launchUrl(Uri.file(path))) {
        ref.read(noticeProvider.notifier).show('No app opens ${a.name}');
      }
    });
  }

  Future<void> _save() => _run(() async {
    final dir = await getDownloadsDirectory();
    if (dir == null) throw StateError('No Downloads folder here');
    final path = await ref
        .read(repositoryProvider)
        .saveAttachment(widget.attachment, dir.path);
    ref
        .read(noticeProvider.notifier)
        .show('Saved to Downloads/${path.split(Platform.pathSeparator).last}');
  });

  @override
  Widget build(BuildContext context) {
    final a = widget.attachment;
    return Tooltip(
      message: kTouch ? '' : 'Open ${a.name}',
      waitDuration: const Duration(milliseconds: 600),
      child: HoverRegion(
        onTap: _open,
        builder: (context, hovered) => _ChipFrame(
          icon: iconForFile(a.mime, a.name),
          name: a.name,
          size: a.sizeLabel,
          hovered: hovered,
          busy: _busy,
          trailing: kTouch
              ? null
              : Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: IconBtn(
                    icon: CupertinoIcons.arrow_down_to_line,
                    label: 'Save to Downloads',
                    size: 13,
                    onTap: _busy ? null : _save,
                  ),
                ),
        ),
      ),
    );
  }
}

/// A file attached to a draft, with a remove button.
class DraftFileChip extends StatelessWidget {
  const DraftFileChip({super.key, required this.file, required this.onRemove});
  final DraftAttachment file;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return HoverRegion(
      builder: (context, hovered) => _ChipFrame(
        icon: iconForFile(file.mime, file.name),
        name: file.name,
        size: formatBytes(file.size),
        hovered: hovered,
        muted: file.fromMessage,
        trailing: Padding(
          padding: const EdgeInsets.only(left: 4),
          child: IconBtn(
            icon: CupertinoIcons.xmark,
            label: 'Remove',
            size: 11,
            onTap: onRemove,
          ),
        ),
      ),
    );
  }
}
