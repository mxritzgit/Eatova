part of 'profile_widgets.dart';

/// The weigh-in paths beyond "log now" (review 2026-10-19): a dated
/// weigh-in, and the history with edit and delete. The shell binds them to
/// its store; these widgets only see this.
class WeighInActions {
  const WeighInActions({
    required this.changes,
    required this.log,
    required this.logAt,
    required this.update,
    required this.delete,
  });

  /// Notifies when [log] may have changed; the history follows it live.
  final Listenable changes;
  final WeightLog Function() log;

  /// Saves a new weigh-in at [at]; null is now.
  final Future<void> Function(double kg, DateTime? at) logAt;

  /// Corrects the weigh-in with row id `id`.
  final Future<void> Function(String id, double kg, DateTime at) update;

  /// Deletes the weigh-in with row id `id`; the store offers the undo.
  final Future<void> Function(String id) delete;
}

/// How far back a weigh-in can be dated: the history's year.
const Duration kWeighInMaxBackdate = Duration(days: 365);

/// The weigh-in sheet's request to show the history once it has closed.
class _OpenWeighInHistory {
  const _OpenWeighInHistory();
}

/// All weigh-ins, newest first; a row opens the edit sheet. Follows
/// [WeighInActions.changes], so an edit, a delete and its undo show at once.
Future<void> showWeighInHistorySheet(
  BuildContext context,
  WeighInActions actions,
) => showEatovaSheet<void>(
  context,
  _WeighInHistorySheet(actions: actions),
  dragHandle: false,
);

Future<void> _showWeighInEditSheet(
  BuildContext context,
  WeighInActions actions,
  WeightLogEntry entry,
) => showEatovaSheet<Object>(
  context,
  _ProfileWeightInputSheet(
    initial: entry.weightKg,
    onSave: (_) {},
    actions: actions,
    editing: entry,
  ),
  dragHandle: false,
);

class _WeighInHistorySheet extends StatelessWidget {
  const _WeighInHistorySheet({required this.actions});

  final WeighInActions actions;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    return Column(
      key: const ValueKey('weigh-in-history'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SheetHandle(
          padding: const EdgeInsets.symmetric(vertical: 11),
          onDismiss: () => Navigator.of(context).maybePop(),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          child: HeadingSemantics(
            level: 1,
            child: Text(
              l10n.weightLogHistoryTitle,
              style: AppType.display(24, color: t.ink),
            ),
          ),
        ),
        Flexible(
          child: ListenableBuilder(
            listenable: actions.changes,
            builder: (context, _) {
              final entries = actions.log().entries.reversed.toList();
              if (entries.isEmpty) {
                return Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
                  child: Text(
                    l10n.weightLogHistoryEmpty,
                    key: const ValueKey('weigh-in-history-empty'),
                    style: AppType.ui(13.5, color: t.ink2, height: 1.45),
                  ),
                );
              }
              return SafeArea(
                top: false,
                child: ListView.separated(
                  shrinkWrap: true,
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                  itemCount: entries.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, i) {
                    final entry = entries[i];
                    return _WeighInRow(
                      entry: entry,
                      onTap: entry.id == null
                          ? null
                          : () => _showWeighInEditSheet(context, actions, entry),
                    );
                  },
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// One weigh-in: day and time on the left, the value on the right. A row
/// an older build cached without its id waits for the next server load.
class _WeighInRow extends StatelessWidget {
  const _WeighInRow({required this.entry, this.onTap});

  final WeightLogEntry entry;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final day = formatWeighInDay(entry.timestamp, l10n);
    final time = formatWeighInTime(context, entry.timestamp);
    final kg = formatKgDe(entry.weightKg, l10n);
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(rControl),
    );
    return Semantics(
      button: onTap != null,
      label: onTap == null
          ? '$day, $time, $kg kg. ${l10n.weightLogHistoryNotEditable}'
          : l10n.weightLogHistoryRowSemantics('$day, $time', kg),
      excludeSemantics: true,
      child: Material(
        color: t.surf,
        shape: shape,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: ValueKey('weigh-in-row-${entry.id ?? entry.timestamp}'),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 56),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(
                          '$day · $time',
                          style: AppType.ui(
                            14,
                            weight: FontWeight.w600,
                            color: t.ink,
                          ),
                        ),
                        if (onTap == null) ...<Widget>[
                          const SizedBox(height: 2),
                          Text(
                            l10n.weightLogHistoryNotEditable,
                            style: AppType.ui(12, color: t.ink3),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    '$kg kg',
                    style: AppType.ui(
                      15,
                      weight: FontWeight.w700,
                      color: t.ink,
                    ),
                  ),
                  if (onTap != null) ...<Widget>[
                    const SizedBox(width: 6),
                    Icon(Icons.chevron_right_rounded, size: 20, color: t.ink3),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// "Today", "Yesterday" or the short weekday and date (`de` "Mo., 19. Okt.").
String formatWeighInDay(DateTime at, AppLocalizations l10n) {
  final local = at.toLocal();
  final now = clock.now();
  final days = DateUtils.dateOnly(now).difference(DateUtils.dateOnly(local));
  // Calendar days, not 24 h spans: DST keeps the two dates whole.
  final back = (days.inHours / 24).round();
  if (back == 0) return l10n.todayDateToday;
  if (back == 1) return l10n.todayDateYesterday;
  if (!_dateSymbolsReady) {
    initializeDateFormatting();
    _dateSymbolsReady = true;
  }
  return local.year == now.year
      ? DateFormat.MMMEd(l10n.localeName).format(local)
      : DateFormat.yMMMEd(l10n.localeName).format(local);
}

/// The time the way the device shows times (24 h or 12 h by locale).
String formatWeighInTime(BuildContext context, DateTime at) =>
    MaterialLocalizations.of(context).formatTimeOfDay(
      TimeOfDay.fromDateTime(at.toLocal()),
      alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
    );

/// The weigh-in sheet's moment: the day strip (no day after today, none
/// before [firstDate]) and the time; the time pill reads "Now" while
/// [time] is null.
class _WeighInWhen extends StatelessWidget {
  const _WeighInWhen({
    required this.day,
    required this.time,
    required this.firstDate,
    required this.onDay,
    required this.onTime,
  });

  final DateTime day;
  final TimeOfDay? time;
  final DateTime firstDate;
  final ValueChanged<DateTime> onDay;
  final ValueChanged<TimeOfDay> onTime;

  Future<void> _pickTime(BuildContext context) async {
    final initial = time ?? TimeOfDay.fromDateTime(clock.now());
    // As the reminder picker: a 24-hour locale gets the 24-hour flag too,
    // or typing "7" after a PM start became 19:00.
    final use24h =
        MediaQuery.alwaysUse24HourFormatOf(context) ||
        hourFormat(of: MaterialLocalizations.of(context).timeOfDayFormat()) !=
            HourFormat.h;
    final picked = await showTimePicker(
      context: context,
      initialTime: initial,
      helpText: context.l10n.weighInWhenLabel,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: use24h),
        child: child!,
      ),
    );
    if (picked != null) onTime(picked);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final today = DateUtils.dateOnly(clock.now());
    final shown = time;
    final timeLabel = shown == null
        ? l10n.weighInNow
        : MaterialLocalizations.of(context).formatTimeOfDay(
            shown,
            alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            l10n.weighInWhenLabel,
            style: AppType.ui(13, weight: FontWeight.w600, color: t.ink2),
          ),
        ),
        const SizedBox(height: 8),
        TodayDayStrip(
          key: const ValueKey('weigh-in-day-strip'),
          selectedDate: day,
          today: today,
          firstDate: firstDate,
          onSelected: (picked) => onDay(DateUtils.dateOnly(picked)),
        ),
        const SizedBox(height: 10),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: SoftPillButton(
            key: const ValueKey('weigh-in-time'),
            label: timeLabel,
            icon: Icons.schedule_rounded,
            tone: SoftPillTone.neutral,
            semanticLabel: l10n.weighInTimeSemantics(timeLabel),
            onTap: () => _pickTime(context),
          ),
        ),
      ],
    );
  }
}
