import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../../platform.dart';
import '../../theme/app_icons.dart';
import '../../theme/motion.dart';
import '../../theme/surfaces.dart';
import '../../theme/tokens.dart';

/// A [Problem] as a small block: the title in red, what to do in plain text, and the
/// server's own words folded away for whoever needs them.
class ProblemNote extends StatefulWidget {
  const ProblemNote(this.problem, {super.key});
  final Problem problem;

  @override
  State<ProblemNote> createState() => _ProblemNoteState();
}

class _ProblemNoteState extends State<ProblemNote> {
  bool _details = false;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final p = widget.problem;
    // Phones read it at arm's length: larger type, a larger icon, a 48 place to tap.
    final touch = kTouch;
    final indent = touch ? 26.0 : 19.0;
    final stage = switch (p.stage) {
      'imap' => 'Incoming server: ',
      'smtp' => 'Outgoing server: ',
      _ => '',
    };
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: s.red.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: s.red.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(
                  touch
                      ? AppIcons.error
                      : CupertinoIcons.exclamationmark_circle,
                  size: touch ? 18 : 13,
                  color: s.red,
                ),
              ),
              SizedBox(width: touch ? 8 : 6),
              Expanded(
                child: Text(
                  '$stage${p.title}',
                  style: ui(
                    context,
                    size: touch ? 15 : 12.5,
                    weight: touch ? FontWeight.w600 : FontWeight.w500,
                    color: s.red,
                  ),
                ),
              ),
            ],
          ),
          if (p.hint != null)
            Padding(
              padding: EdgeInsets.only(left: indent, top: 3),
              child: SelectableText(
                p.hint!,
                style: ui(
                  context,
                  size: touch ? 14 : 12,
                  color: s.fg2,
                  height: 1.4,
                ),
              ),
            ),
          if (p.detail.isNotEmpty)
            Padding(
              padding: EdgeInsets.only(left: indent, top: touch ? 0 : 4),
              child: HoverRegion(
                onTap: () => setState(() => _details = !_details),
                builder: (context, hovered) => Container(
                  constraints: BoxConstraints(
                    minHeight: touch ? Touch.target : 0,
                  ),
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _details ? 'Hide server reply' : 'Server reply',
                    style: touch
                        ? ui(context, size: 14, color: s.fg2)
                        : mono(
                            context,
                            size: 11,
                            color: hovered ? s.fg2 : s.fg3,
                          ),
                  ),
                ),
              ),
            ),
          AnimatedSize(
            duration: Motion.of(context, Motion.fast),
            curve: Motion.curve,
            alignment: Alignment.topLeft,
            child: _details
                ? Padding(
                    padding: EdgeInsets.only(left: indent, top: 4),
                    child: SelectableText(
                      p.detail,
                      // Read at arm's length on a phone: readable contrast.
                      style: mono(
                        context,
                        size: touch ? 13 : 11,
                        color: touch ? s.fg2 : s.fg3,
                      ),
                    ),
                  )
                : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }
}
