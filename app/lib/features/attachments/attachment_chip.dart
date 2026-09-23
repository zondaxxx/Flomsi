import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/models.dart';
import '../../data/repository.dart';
import '../../platform.dart';
import '../../state/providers.dart';
import '../../theme/motion.dart';
import '../../theme/surfaces.dart';
import '../../theme/tokens.dart';

/// Glyph for a file by its extension: what the system will open it as. The MIME type the
/// sender claimed only helps when there is no extension.
IconData iconForFile(String mime, String name) {
  final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
  const images = {
    'png',
    'jpg',
    'jpeg',
    'gif',
    'webp',
    'heic',
    'bmp',
    'tif',
    'tiff',
  };
  const video = {'mp4', 'mov', 'm4v', 'webm', 'avi', 'mkv'};
  const audio = {'mp3', 'm4a', 'wav', 'aac', 'ogg', 'flac'};
  const archives = {'zip', 'rar', '7z', 'gz', 'tar', 'tgz', 'bz2', 'xz'};
  const docs = {
    'pdf',
    'txt',
    'md',
    'rtf',
    'doc',
    'docx',
    'odt',
    'xls',
    'xlsx',
    'ods',
    'csv',
    'ppt',
    'pptx',
    'odp',
    'pages',
    'numbers',
    'key',
  };
  if (ext.isNotEmpty) {
    if (images.contains(ext)) return CupertinoIcons.photo;
    if (video.contains(ext)) return CupertinoIcons.film;
    if (audio.contains(ext)) return CupertinoIcons.music_note;
    if (ext == 'eml') return CupertinoIcons.envelope;
    if (archives.contains(ext)) return CupertinoIcons.archivebox;
    if (ext == 'ics') return CupertinoIcons.calendar;
    if (docs.contains(ext)) return CupertinoIcons.doc_text;
    return CupertinoIcons.doc;
  }
  final m = mime.toLowerCase();
  if (m.startsWith('image/')) return CupertinoIcons.photo;
  if (m.startsWith('text/') || m == 'application/pdf') {
    return CupertinoIcons.doc_text;
  }
  return CupertinoIcons.doc;
}

/// A name's extension with its dot (`.pdf`), when it has a short one; else empty.
String fileExtension(String name) {
  final dot = name.lastIndexOf('.');
  return dot > 0 && name.length - dot <= 12 ? name.substring(dot) : '';
}

/// Shorten a file name in the middle so the extension always shows: a disguised
/// `invoice-2026-09-final-final.pdf.exe` must not end in `…`. Counts and cuts whole
/// characters as people see them, so an emoji is never split in half.
String middleEllipsis(String name, {int max = 34}) {
  final all = name.characters;
  if (all.length <= max) return name;
  final ext = fileExtension(name);
  final stem = name.substring(0, name.length - ext.length).characters;
  final keep = (max - ext.characters.length - 1).clamp(4, max);
  final head = (keep * 2 / 3).round().clamp(1, stem.length);
  final tail = (keep - head).clamp(0, stem.length - head);
  return '${stem.take(head)}…${stem.takeLast(tail)}$ext';
}

String _reason(Object e) =>
    e.toString().replaceFirst(RegExp(r'^[\w ]*(Exception|Error): '), '');

/// Files that can run code are never opened from Flomsi. On a computer they can be saved
/// after a clear question; on a phone, handed to another app the same way. True when the
/// person chose to go on.
Future<bool> allowRiskyAttachment(
  BuildContext context,
  MailRepository repo,
  Attachment a,
  String ext,
) {
  final name = repo.displayFileName(a.name);
  return confirmDialog(
    context,
    title: 'This is a .$ext file',
    body: kTouch
        ? '“$name” can run code or open a web page when it is opened. Share it only if you expected it from this sender.'
        : '“$name” can run code or open a web page when it is opened, so Flomsi does not open it. Save it to Downloads if you expected it from this sender.',
    action: kTouch ? 'Share anyway' : 'Save to Downloads',
    danger: true,
  );
}

/// A phone: fetch the file if needed and hand it to another app through the share sheet,
/// which points at [origin] on an iPad. Failures become a notice.
Future<void> shareAttachment(
  MailRepository repo,
  NoticeController notice,
  Attachment a, {
  Rect? origin,
}) async {
  try {
    final path = await repo.openAttachment(a);
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(path, mimeType: a.mime)],
        sharePositionOrigin: origin,
      ),
    );
  } catch (e) {
    notice.show(_reason(e));
  }
}

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
    this.risky,
  });
  final IconData icon;
  final String name;
  final String size;
  final bool hovered;
  final bool busy;
  final bool muted;
  final Widget? trailing;

  /// Extension of a file that can run code: shown as a red tag.
  final String? risky;

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
          // The extension is laid out on its own and never cut: a wide name gives way
          // with an ellipsis before it, on a phone as on a desktop.
          Flexible(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 260),
              child: Builder(
                builder: (context) {
                  final shown = middleEllipsis(name);
                  final ext = fileExtension(shown);
                  final style = mono(
                    context,
                    size: 12,
                    color: muted ? s.fg2 : s.fg,
                  );
                  // Read out as one name, not a stem and an extension.
                  return Semantics(
                    label: name,
                    excludeSemantics: true,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            shown.substring(0, shown.length - ext.length),
                            maxLines: 1,
                            softWrap: false,
                            overflow: TextOverflow.ellipsis,
                            style: style,
                          ),
                        ),
                        if (ext.isNotEmpty)
                          Text(ext, maxLines: 1, softWrap: false, style: style),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
          if (risky != null) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                border: Border.all(color: s.red.withValues(alpha: 0.6)),
                borderRadius: BorderRadius.circular(3),
              ),
              child: Text(
                '.$risky',
                style: mono(context, size: 10.5, color: s.red),
              ),
            ),
          ],
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
    if (_busy || !mounted) return;
    setState(() => _busy = true);
    try {
      await job();
    } catch (e) {
      ref.read(noticeProvider.notifier).show(_reason(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _allowRisky(String ext) => allowRiskyAttachment(
    context,
    ref.read(repositoryProvider),
    widget.attachment,
    ext,
  );

  Future<void> _open() async {
    final a = widget.attachment;
    final risky = ref.read(repositoryProvider).riskyExtension(a.name);
    if (risky != null) {
      if (!await _allowRisky(risky) || !mounted) return;
      if (!kTouch) return _save();
    }
    if (!mounted) return;
    final box = context.findRenderObject() as RenderBox?;
    final origin = box == null
        ? null
        : box.localToGlobal(Offset.zero) & box.size;
    final repo = ref.read(repositoryProvider);
    final notice = ref.read(noticeProvider.notifier);
    return _run(() async {
      if (kTouch) {
        return shareAttachment(repo, notice, a, origin: origin);
      }
      final path = await repo.openAttachment(a);
      if (!await launchUrl(Uri.file(path))) {
        notice.show('No app opens ${a.name}');
      }
    });
  }

  Future<void> _saveAsked() async {
    final risky = ref
        .read(repositoryProvider)
        .riskyExtension(widget.attachment.name);
    if (risky != null && (!await _allowRisky(risky) || !mounted)) return;
    return _save();
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
    final repo = ref.read(repositoryProvider);
    final name = repo.displayFileName(a.name);
    final risky = repo.riskyExtension(a.name);
    return Tooltip(
      message: kTouch ? '' : (risky == null ? 'Open $name' : name),
      waitDuration: const Duration(milliseconds: 600),
      child: HoverRegion(
        onTap: _open,
        builder: (context, hovered) => _ChipFrame(
          icon: risky == null
              ? iconForFile(a.mime, name)
              : CupertinoIcons.exclamationmark_shield,
          name: name,
          size: a.sizeLabel,
          hovered: hovered,
          busy: _busy,
          risky: risky,
          trailing: kTouch
              ? null
              : Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: IconBtn(
                    icon: CupertinoIcons.arrow_down_to_line,
                    label: 'Save to Downloads',
                    size: 13,
                    onTap: _busy ? null : _saveAsked,
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
