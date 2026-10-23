import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/app_theme.dart';
import '../../core/utils/poll_tally.dart';
import '../../data/models/models.dart';

/// v0.1.10 — encrypted poll bubble.
///
/// Question and options arrive decrypted from the E2E payload; the
/// tally is computed on-device from the chat's synced ballots. Tapping
/// an option casts (or changes) my vote — the bubble re-renders live
/// because ballots arrive through the normal realtime pipeline.
class PollBubble extends StatelessWidget {
  final Message pollMsg;
  final bool mine;
  final List<Message> chatMessages;
  final String myId;
  final double font;
  final void Function(int optionIndex) onVote;

  const PollBubble({
    super.key,
    required this.pollMsg,
    required this.mine,
    required this.chatMessages,
    required this.myId,
    required this.font,
    required this.onVote,
  });

  @override
  Widget build(BuildContext context) {
    final poll = pollMsg.poll;
    if (poll == null || poll.options.isEmpty) {
      // Defensive: a poll row without a decodable body renders as a
      // locked placeholder instead of crashing the transcript.
      return Container(
        constraints: const BoxConstraints(maxWidth: 300),
        padding: const EdgeInsets.all(12),
        decoration: _deco(context),
        child: Text('🔒 استطلاع غير قابل للقراءة بهذا الجهاز',
            style: TextStyle(fontSize: font, color: _fg(context))),
      );
    }

    final tally = PollTally.tally(pollMsg, chatMessages);
    final myVote = PollTally.myVote(tally, myId);
    final voters = PollTally.totalVoters(tally);
    final fg = _fg(context);

    return Container(
      constraints: const BoxConstraints(maxWidth: 320),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: _deco(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // ---------- header ----------
          Row(
            children: [
              Icon(Icons.poll_rounded, size: 17, color: _accent(context)),
              const SizedBox(width: 5),
              Text('استطلاع رأي',
                  style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      color: _accent(context))),
            ],
          ),
          const SizedBox(height: 5),
          Text(
            poll.question,
            style: TextStyle(
                fontSize: font + 1,
                height: 1.35,
                fontWeight: FontWeight.w700,
                color: fg),
          ),
          const SizedBox(height: 10),
          // ---------- options ----------
          for (var i = 0; i < poll.options.length; i++)
            _OptionRow(
              label: poll.options[i],
              percent: PollTally.percent(tally, i),
              isMine: myVote == i,
              hasVotes: voters > 0,
              mine: mine,
              font: font,
              onTap: () {
                HapticFeedback.selectionClick();
                onVote(i);
              },
            ),
          const SizedBox(height: 8),
          // ---------- footer ----------
          Text(
            voters == 0
                ? 'لا أصوات بعد — اضغط على خيار للتصويت'
                : myVote == null
                    ? '$voters صوت — اضغط للتصويت'
                    : '$voters صوت — صوّتت، اضغط لخيار آخر للتغيير',
            style: TextStyle(
                fontSize: 11,
                color: fg.withValues(alpha: 0.65)),
          ),
        ],
      ),
    );
  }

  Color _fg(BuildContext context) =>
      mine ? Colors.white : Theme.of(context).colorScheme.onSurface;

  Color _accent(BuildContext context) =>
      mine ? Colors.white : AppTheme.brandSecondary;

  BoxDecoration _deco(BuildContext context) => BoxDecoration(
        gradient: mine ? AppTheme.brandGradient : null,
        color: mine ? null : AppTheme.brandPrimary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(18),
        border: mine
            ? null
            : Border.all(color: AppTheme.brandPrimary.withValues(alpha: 0.25)),
      );
}

class _OptionRow extends StatelessWidget {
  final String label;
  final int percent;
  final bool isMine;
  final bool hasVotes;
  final bool mine;
  final double font;
  final VoidCallback onTap;

  const _OptionRow({
    required this.label,
    required this.percent,
    required this.isMine,
    required this.hasVotes,
    required this.mine,
    required this.font,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final fg = mine ? Colors.white : Theme.of(context).colorScheme.onSurface;
    final fill = mine
        ? Colors.white.withValues(alpha: 0.22)
        : AppTheme.brandPrimary.withValues(alpha: 0.18);
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Stack(
            children: [
              // progress fill
              if (hasVotes)
                PositionedDirectional(
                  start: 0,
                  top: 0,
                  bottom: 0,
                  width: MediaQuery.of(context).size.width *
                      0.62 *
                      (percent / 100),
                  child: Container(color: fill),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(9, 7, 9, 7),
                child: Row(
                  children: [
                    Icon(
                      isMine
                          ? Icons.check_circle_rounded
                          : Icons.radio_button_unchecked_rounded,
                      size: 18,
                      color: isMine
                          ? (mine ? Colors.white : AppTheme.brandSecondary)
                          : fg.withValues(alpha: 0.45),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        label,
                        style: TextStyle(
                            fontSize: font,
                            height: 1.3,
                            fontWeight:
                                isMine ? FontWeight.w700 : FontWeight.w500,
                            color: fg),
                      ),
                    ),
                    if (hasVotes)
                      Text(
                        '$percent%',
                        style: TextStyle(
                            fontSize: font - 2,
                            fontWeight: FontWeight.w700,
                            color: fg.withValues(alpha: 0.75)),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// v0.1.10 — create-poll sheet. Question + 2..12 options; publishes an
/// encrypted poll through [onPublish] when validation passes.
Future<void> showPollComposerSheet(
  BuildContext context, {
  required void Function(String question, List<String> options) onPublish,
}) async {
  final questionCtrl = TextEditingController();
  final optionCtrls = <TextEditingController>[
    TextEditingController(),
    TextEditingController(),
  ];

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetCtx) => StatefulBuilder(
      builder: (sheetCtx, setSheetState) {
        void addOption() {
          if (optionCtrls.length >= 12) return;
          setSheetState(() => optionCtrls.add(TextEditingController()));
        }

        void publish() {
          final q = questionCtrl.text.trim();
          final opts = optionCtrls
              .map((c) => c.text.trim())
              .where((o) => o.isNotEmpty)
              .toList();
          if (q.isEmpty || opts.length < 2) {
            HapticFeedback.heavyImpact();
            return;
          }
          Navigator.of(sheetCtx).pop();
          onPublish(q, opts);
        }

        return Padding(
          padding: EdgeInsets.only(
              bottom: MediaQuery.of(sheetCtx).viewInsets.bottom),
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('استطلاع رأي مشفر',
                      textAlign: TextAlign.center,
                      style: Theme.of(sheetCtx).textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text('يُرسل السؤال والخيارات مشفرة طرف-لطرف',
                      textAlign: TextAlign.center,
                      style: Theme.of(sheetCtx).textTheme.bodySmall),
                  const SizedBox(height: 14),
                  TextField(
                    controller: questionCtrl,
                    maxLines: 1,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(
                      labelText: 'السؤال',
                      prefixIcon: Icon(Icons.help_outline_rounded),
                    ),
                  ),
                  const SizedBox(height: 10),
                  for (var i = 0; i < optionCtrls.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: optionCtrls[i],
                              maxLines: 1,
                              decoration: InputDecoration(
                                labelText: 'الخيار ${i + 1}',
                                prefixIcon:
                                    const Icon(Icons.check_box_outline_blank,
                                        size: 20),
                                suffixIcon: optionCtrls.length > 2
                                    ? IconButton(
                                        icon: const Icon(Icons.close_rounded,
                                            size: 18),
                                        onPressed: () => setSheetState(() {
                                              optionCtrls[i].dispose();
                                              optionCtrls.removeAt(i);
                                            }),
                                      )
                                    : null,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (optionCtrls.length < 12)
                    TextButton.icon(
                      onPressed: addOption,
                      icon: const Icon(Icons.add_rounded, size: 18),
                      label: const Text('إضافة خيار'),
                    ),
                  const SizedBox(height: 6),
                  FilledButton.icon(
                    onPressed: publish,
                    style: FilledButton.styleFrom(
                      backgroundColor: AppTheme.brandPrimary,
                    ),
                    icon: const Icon(Icons.poll_rounded, size: 19),
                    label: const Text('نشر الاستطلاع'),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    ),
  );
}
