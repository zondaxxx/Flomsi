import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../data/models.dart';
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
                  CupertinoIcons.exclamationmark_circle,
                  size: 13,
                  color: s.red,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '$stage${p.title}',
                  style: ui(
                    context,
                    size: 12.5,
                    weight: FontWeight.w500,
                    color: s.red,
                  ),
                ),
              ),
            ],
          ),
          if (p.hint != null)
            Padding(
              padding: const EdgeInsets.only(left: 19, top: 3),
              child: SelectableText(
                p.hint!,
                style: ui(context, size: 12, color: s.fg2, height: 1.4),
              ),
            ),
          if (p.detail.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 19, top: 4),
              child: HoverRegion(
                onTap: () => setState(() => _details = !_details),
                builder: (context, hovered) => Text(
                  _details ? 'Hide server reply' : 'Server reply',
                  style: mono(
                    context,
                    size: 11,
                    color: hovered ? s.fg2 : s.fg3,
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
                    padding: const EdgeInsets.only(left: 19, top: 4),
                    child: SelectableText(
                      p.detail,
                      style: mono(context, size: 11, color: s.fg3),
                    ),
                  )
                : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }
}
