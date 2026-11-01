import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import '../../app/timer_alerts_scope.dart';
import '../../l10n/l10n.dart';
import '../../models/cooking_timers.dart';
import '../../services/rest_alert_guard.dart';
import '../../services/rest_alerts.dart';
import '../../services/screen_awake.dart';
import '../../services/uuid.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/common/motion.dart';
import '../../widgets/design/design.dart';
import '../../widgets/recipes/recipe_sections.dart';
import '../training/player/player_format.dart' show ceilSeconds, formatClock;

/// Owner of the cooking mode's keep-awake hold ([ScreenAwake]).
const String cookingModeAwakeOwner = 'cooking-mode';

/// Largest text scale the 24 px step text follows (36 px).
const double _stepMaxScale = 1.5;

/// "1 Stunde 30 Minuten": a timer's length in words, for its button, its
/// screen-reader label and its alert.
String cookingDurationText(Duration length, AppLocalizations l) {
  final hours = length.inHours;
  final minutes = length.inMinutes % 60;
  final seconds = length.inSeconds % 60;
  return [
    if (hours > 0) l.cookingDurationHours(hours),
    if (minutes > 0) l.cookingDurationMinutes(minutes),
    if (seconds > 0) l.cookingDurationSeconds(seconds),
  ].join(' ');
}

/// Opens the cooking mode over the current route: [steps] one per page,
/// [ingredients] as the caller shows them for its servings. Timers ring
/// through the app's local alerts ([TimerAlertsScope]), pinned to the
/// account by [isSessionCurrent]. True once [onEat] logged the meal.
Future<bool> openCookingMode(
  BuildContext context, {
  required List<String> steps,
  required String ingredients,
  String ingredientsHint = '',
  Future<bool> Function()? onEat,
  bool Function()? isSessionCurrent,
}) async {
  final scheduler = TimerAlertsScope.schedulerOf(context);
  final restAlerts = GuardedRestAlertScheduler(
    scheduler ?? const NoopRestAlertScheduler(),
    () => isSessionCurrent?.call() ?? true,
  );
  final permission = scheduler == null
      ? null
      : TimerAlertsScope.permissionOf(context);
  final eaten = await Navigator.of(context).push<bool>(
    MaterialPageRoute<bool>(
      builder: (_) => CookingModeScreen(
        steps: steps,
        ingredients: ingredients,
        ingredientsHint: ingredientsHint,
        onEat: onEat,
        restAlerts: restAlerts,
        alertPermission: permission,
      ),
    ),
  );
  return eaten ?? false;
}

/// One running (or run-out) timer of a step.
class _CookingTimer {
  _CookingTimer({
    required this.step,
    required this.length,
    required this.endsAt,
  });

  final int step;
  final Duration length;
  final DateTime endsAt;

  /// The deadline passed.
  bool up = false;

  /// Its alert was cancelled after the deadline (rung in the foreground, or
  /// seen after a return to the app).
  bool settled = false;
}

/// The cooking mode: one step per page in large type, swiped or stepped
/// through, a timer button per time a step names ([cookingTimersIn]), the
/// ingredients on demand, and the display kept on while it is open.
///
/// A running timer schedules the training rests' local alert under its own
/// id ([cookingTimerIdFor]), so it rings with the phone locked; a deadline
/// seen in the foreground rings in the app. Leaving with a timer running
/// asks first; leaving ends every timer.
class CookingModeScreen extends StatefulWidget {
  const CookingModeScreen({
    super.key,
    required this.steps,
    this.ingredients = '',
    this.ingredientsHint = '',
    this.onEat,
    this.restAlerts = const NoopRestAlertScheduler(),
    this.alertPermission,
    this.screenAwake = const MethodChannelScreenAwake(),
    this.openAlertSettings = openNotificationSettings,
  });

  /// At least one; the recipe detail offers the mode from two.
  final List<String> steps;
  final String ingredients;
  final String ingredientsHint;

  /// Opened from the meal plan: the last step logs the planned meal through
  /// the plan, true once eaten. Null ends with "Done".
  final Future<bool> Function()? onEat;
  final RestAlertScheduler restAlerts;

  /// Null where notifications are unavailable: timers ring in the app only.
  final RestAlertPermissionGate? alertPermission;
  final ScreenAwake screenAwake;
  final Future<void> Function() openAlertSettings;

  @override
  State<CookingModeScreen> createState() => _CookingModeScreenState();
}

class _CookingModeScreenState extends State<CookingModeScreen>
    with WidgetsBindingObserver {
  /// Fresh per visit, so no timer id repeats across visits or accounts.
  final String _visitId = uuidV4();
  final PageController _pages = PageController();
  late final List<List<Duration>> _stepTimers = [
    for (final step in widget.steps) cookingTimersIn(step),
  ];

  /// First timer slot of each step: a slot numbers a timer within the visit.
  late final List<int> _slotBase = _firstSlots(_stepTimers);
  final Map<int, _CookingTimer> _timers = {};
  Timer? _ticker;
  int _page = 0;

  // Null until the gate answers: no hint, nothing planned yet.
  RestAlertPermission? _permission;
  bool _permissionBusy = false;
  bool _leaveAsked = false;
  bool _leaving = false;
  bool _eating = false;

  static List<int> _firstSlots(List<List<Duration>> stepTimers) {
    final first = <int>[];
    var next = 0;
    for (final timers in stepTimers) {
      first.add(next);
      next += timers.length;
    }
    return first;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(
      _quiet(
        widget.screenAwake.setKeepAwake(true, owner: cookingModeAwakeOwner),
      ),
    );
    _readPermission();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.cancel();
    for (final slot in _timers.keys) {
      unawaited(_quiet(widget.restAlerts.cancelRestAlert(_alertId(slot))));
    }
    unawaited(
      _quiet(
        widget.screenAwake.setKeepAwake(false, owner: cookingModeAwakeOwner),
      ),
    );
    _pages.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    // A deadline passed away from the app rang as the OS alert; drop the
    // alert (Android may still hold it back) and show the timer as up.
    _tick(seen: false);
    for (final MapEntry(key: slot, value: timer) in _timers.entries) {
      if (timer.up && !timer.settled) {
        timer.settled = true;
        unawaited(_quiet(widget.restAlerts.cancelRestAlert(_alertId(slot))));
      }
    }
    _readPermission();
  }

  int _slot(int step, int index) => _slotBase[step] + index;

  int _alertId(int slot) => cookingTimerIdFor(_visitId, slot);

  int get _running => _timers.values.where((timer) => !timer.up).length;

  /// On screen, also under the pulled-down shade or a system dialog.
  bool get _foreground => switch (WidgetsBinding.instance.lifecycleState) {
    null || AppLifecycleState.resumed || AppLifecycleState.inactive => true,
    _ => false,
  };

  // --- Timers ---------------------------------------------------------------

  void _start(int step, int index) {
    final length = _stepTimers[step][index];
    final slot = _slot(step, index);
    final timer = _CookingTimer(
      step: step,
      length: length,
      endsAt: clock.now().add(length),
    );
    setState(() => _timers[slot] = timer);
    _ticker ??= Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    _plan(slot, timer);
  }

  /// Stop (running) or dismiss (up): the timer and its alert go.
  void _clear(int slot) {
    setState(() => _timers.remove(slot));
    unawaited(_quiet(widget.restAlerts.cancelRestAlert(_alertId(slot))));
    _stopTickerWhenIdle();
  }

  void _plan(int slot, _CookingTimer timer) {
    if (timer.up || !_alertsAllowed) return;
    final l = context.l10n;
    unawaited(
      _quiet(
        widget.restAlerts.scheduleRestAlert(
          id: _alertId(slot),
          at: timer.endsAt,
          title: l.cookingTimerAlertTitle,
          body: l.cookingTimerAlertBody(
            timer.step + 1,
            cookingDurationText(timer.length, l),
          ),
        ),
      ),
    );
  }

  /// Once a second while a timer runs. [seen]: the app is in front, so a
  /// deadline rings here.
  void _tick({bool seen = true}) {
    if (!mounted) return;
    final now = clock.now();
    final ring = seen && _foreground;
    for (final MapEntry(key: slot, value: timer) in _timers.entries) {
      if (timer.up || now.isBefore(timer.endsAt)) continue;
      timer.up = true;
      if (ring) _ring(slot, timer);
    }
    _stopTickerWhenIdle();
    setState(() {});
  }

  void _stopTickerWhenIdle() {
    if (_running > 0) return;
    _ticker?.cancel();
    _ticker = null;
  }

  /// A deadline seen in the foreground: a haptic and an announcement, and
  /// the scheduler's cue where it has one (Android, whose inexact alert
  /// would come late and is dropped here).
  void _ring(int slot, _CookingTimer timer) {
    timer.settled = true;
    unawaited(HapticFeedback.vibrate());
    final l = context.l10n;
    final length = cookingDurationText(timer.length, l);
    unawaited(
      SemanticsService.sendAnnouncement(
        View.of(context),
        l.cookingTimerUpAnnouncement(timer.step + 1, length),
        Directionality.of(context),
      ),
    );
    final id = _alertId(slot);
    unawaited(_quiet(widget.restAlerts.cancelRestAlert(id)));
    final cue = switch (widget.restAlerts) {
      final RestAlertCue cue => cue,
      _ => null,
    };
    if (cue == null || !_alertsAllowed) return;
    unawaited(
      _quiet(
        cue.cueRestAlert(
          id: id,
          title: l.cookingTimerAlertTitle,
          body: l.cookingTimerAlertBody(timer.step + 1, length),
        ),
      ),
    );
  }

  // --- Alert permission -----------------------------------------------------

  /// Alerts are planned only with a grant: iOS rejects a request while this
  /// app's notifications are off, each time as a reported error.
  bool get _alertsAllowed =>
      widget.alertPermission == null ||
      _permission == RestAlertPermission.granted;

  bool get _alertsOff =>
      widget.alertPermission != null &&
      _permission != null &&
      _permission != RestAlertPermission.granted;

  /// Silent read, also on every return: alerts turned on in the settings
  /// meanwhile plan the running timers at once. A gate that cannot answer
  /// leaves it to the OS, as without a gate.
  void _readPermission() {
    final gate = widget.alertPermission;
    if (gate == null) return;
    unawaited(
      _quiet(
        gate.state().then(
          _setPermission,
          onError: (Object _) => _setPermission(RestAlertPermission.granted),
        ),
      ),
    );
  }

  void _setPermission(RestAlertPermission state) {
    if (!mounted || state == _permission) return;
    final allowedBefore = _alertsAllowed;
    setState(() => _permission = state);
    if (allowedBefore || !_alertsAllowed) return;
    for (final MapEntry(key: slot, value: timer) in _timers.entries) {
      _plan(slot, timer);
    }
  }

  /// The hint's action: the system prompt while this device never asked,
  /// the notification settings after a real request or denial. No dialog
  /// before it: the tap on the hint is the request in context.
  Future<void> _turnOnAlerts() async {
    final gate = widget.alertPermission;
    if (gate == null || _permissionBusy) return;
    _permissionBusy = true;
    try {
      RestAlertPermission state;
      try {
        state = await gate.state();
      } catch (_) {
        state = RestAlertPermission.denied;
      }
      if (!mounted) return;
      switch (state) {
        case RestAlertPermission.notAsked:
          bool granted;
          try {
            granted = await gate.request();
          } catch (_) {
            granted = false;
          }
          _setPermission(
            granted ? RestAlertPermission.granted : RestAlertPermission.denied,
          );
        case RestAlertPermission.denied:
          _setPermission(state);
          await _quiet(widget.openAlertSettings());
        case RestAlertPermission.granted:
          _setPermission(state);
      }
    } finally {
      _permissionBusy = false;
    }
  }

  // --- Navigation -----------------------------------------------------------

  void _go(int page) {
    if (reducedMotion(context)) {
      _pages.jumpToPage(page);
    } else {
      unawaited(
        _pages.animateToPage(
          page,
          duration: const Duration(milliseconds: 280),
          curve: kMotionCurve,
        ),
      );
    }
  }

  /// Back with a timer running (system back, the edge pull, close, Done).
  Future<void> _confirmLeave() async {
    if (_leaveAsked) return;
    _leaveAsked = true;
    final l = context.l10n;
    final leave = await showEatovaDialog<bool>(
      context: context,
      builder: (dialogContext) => EatovaConfirmDialog(
        key: const ValueKey('cooking-leave-dialog'),
        title: l.cookingModeLeaveTitle(_running),
        body: l.cookingModeLeaveBody,
        icon: Icons.timer_outlined,
        confirmKey: const ValueKey('cooking-leave-confirm'),
        confirmLabel: l.cookingModeLeave,
        cancelKey: const ValueKey('cooking-leave-stay'),
        cancelLabel: l.cookingModeKeepCooking,
        onConfirm: () => Navigator.of(dialogContext).pop(true),
        onCancel: () => Navigator.of(dialogContext).pop(false),
      ),
    );
    _leaveAsked = false;
    if (leave == true && mounted) _leave(false);
  }

  void _leave(bool eaten) {
    setState(() => _leaving = true);
    // PopScope must rebuild before the programmatic pop.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop(eaten);
    });
  }

  Future<void> _eat() async {
    final onEat = widget.onEat;
    if (onEat == null || _eating || _leaving) return;
    setState(() => _eating = true);
    var eaten = false;
    try {
      eaten = await onEat();
    } catch (_) {
      // The plan's own path reports a failure.
    }
    if (!mounted) return;
    setState(() => _eating = false);
    if (eaten) _leave(true);
  }

  void _showIngredients() {
    final l = context.l10n;
    unawaited(
      showEatovaSheet<void>(
        context,
        SheetScaffold(
          title: l.recipesSectionIngredients,
          subtitle: widget.ingredientsHint.isEmpty
              ? l.recipeDetailIngredientsHint
              : widget.ingredientsHint,
          actionLabel: l.cookingModeIngredientsBack,
          children: [RecipeIngredientLines(text: widget.ingredients)],
        ),
      ),
    );
  }

  // --- Build ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l = context.l10n;
    final count = widget.steps.length;
    final elsewhere = [
      for (final entry in _timers.entries)
        if (entry.value.step != _page) entry,
    ];
    return PopScope(
      canPop: _leaving || _running == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_confirmLeave());
      },
      child: Scaffold(
        backgroundColor: t.bg,
        body: SafeArea(
          child: ReadableWidth(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                  child: Row(
                    children: [
                      SquareIconButton(
                        key: const ValueKey('cooking-close'),
                        icon: Icons.close_rounded,
                        semanticLabel: l.cookingModeLeave,
                        onTap: () => Navigator.of(context).maybePop(),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: HeadingSemantics(
                          level: 1,
                          child: Text(
                            l.cookingModeStepOf(_page + 1, count),
                            key: const ValueKey('cooking-step-title'),
                            textAlign: TextAlign.center,
                            style: AppType.display(20, color: t.ink),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      if (widget.ingredients.trim().isEmpty)
                        const SizedBox(width: 44)
                      else
                        SquareIconButton(
                          key: const ValueKey('cooking-ingredients'),
                          icon: Icons.shopping_basket_outlined,
                          semanticLabel: l.cookingModeShowIngredients,
                          onTap: _showIngredients,
                        ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                  child: _StepProgress(count: count, page: _page),
                ),
                if (elsewhere.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final MapEntry(key: slot, value: timer)
                            in elsewhere)
                          SoftPillButton(
                            key: ValueKey('cooking-timer-elsewhere-$slot'),
                            icon: timer.up
                                ? Icons.alarm_on_rounded
                                : Icons.timer_outlined,
                            label: l.cookingTimerOtherStep(
                              timer.step + 1,
                              timer.up ? l.cookingTimerUp : _clockOf(timer),
                            ),
                            onTap: () => _go(timer.step),
                          ),
                      ],
                    ),
                  ),
                Expanded(
                  child: PageView.builder(
                    key: const ValueKey('cooking-pages'),
                    controller: _pages,
                    itemCount: count,
                    onPageChanged: (page) => setState(() => _page = page),
                    itemBuilder: _stepPage,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                  child: _footer(context),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _clockOf(_CookingTimer timer) =>
      formatClock(ceilSeconds(timer.endsAt.difference(clock.now())));

  Widget _stepPage(BuildContext context, int step) {
    final t = context.t;
    final l = context.l10n;
    return SingleChildScrollView(
      key: ValueKey('cooking-step-$step'),
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.steps[step],
            // 24 px is large text already: at 1.5x it outgrows body text at
            // the app's 2x cap and still leaves a few words per line.
            textScaler: MediaQuery.textScalerOf(
              context,
            ).clamp(maxScaleFactor: _stepMaxScale),
            style: AppType.ui(
              24,
              weight: FontWeight.w500,
              color: t.ink,
              height: 1.45,
            ),
          ),
          for (final (index, length) in _stepTimers[step].indexed) ...[
            const SizedBox(height: 16),
            if (_timers[_slot(step, index)] case final timer?)
              _TimerCard(
                key: ValueKey('cooking-timer-${_slot(step, index)}'),
                up: timer.up,
                clock: _clockOf(timer),
                length: cookingDurationText(length, l),
                onClear: () => _clear(_slot(step, index)),
                askAlerts: _permission == RestAlertPermission.notAsked,
                onAlertsOff: _alertsOff
                    ? () => unawaited(_turnOnAlerts())
                    : null,
              )
            else
              SoftPillButton(
                key: ValueKey('cooking-timer-start-${_slot(step, index)}'),
                icon: Icons.timer_outlined,
                label: cookingDurationText(length, l),
                semanticLabel: l.cookingTimerStartLabel(
                  cookingDurationText(length, l),
                ),
                onTap: () => _start(step, index),
              ),
          ],
        ],
      ),
    );
  }

  Widget _footer(BuildContext context) {
    final l = context.l10n;
    final last = _page == widget.steps.length - 1;
    final back = SoftPillButton(
      key: const ValueKey('cooking-back'),
      icon: Icons.chevron_left_rounded,
      label: l.cookingModeBack,
      tone: SoftPillTone.neutral,
      expand: true,
      onTap: _page == 0 ? null : () => _go(_page - 1),
    );
    final forward = !last
        ? PrimaryActionButton(
            key: const ValueKey('cooking-next'),
            label: l.cookingModeNext,
            onTap: () => _go(_page + 1),
          )
        : widget.onEat != null
        ? PrimaryActionButton(
            key: const ValueKey('cooking-eat'),
            icon: Icons.check_rounded,
            label: l.cookingModeEat,
            busy: _eating,
            onTap: _eat,
          )
        : PrimaryActionButton(
            key: const ValueKey('cooking-done'),
            icon: Icons.check_rounded,
            label: l.cookingModeDone,
            onTap: () => Navigator.of(context).maybePop(),
          );
    // Large text stacks the two, so neither label breaks inside a word.
    if (MediaQuery.textScalerOf(context).scale(15) > 22) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [forward, const SizedBox(height: 8), back],
      );
    }
    return Row(
      children: [
        Expanded(flex: 2, child: back),
        const SizedBox(width: 12),
        Expanded(flex: 3, child: forward),
      ],
    );
  }
}

/// One segment per step, lit up to the current one.
class _StepProgress extends StatelessWidget {
  const _StepProgress({required this.count, required this.page});

  final int count;
  final int page;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    // The heading names the step; the bar only shows it.
    return ExcludeSemantics(
      child: Row(
        children: [
          for (var i = 0; i < count; i++) ...[
            if (i > 0) const SizedBox(width: 4),
            Expanded(
              child: Container(
                height: 4,
                decoration: BoxDecoration(
                  color: i <= page ? t.accent : t.tile,
                  borderRadius: BorderRadius.circular(rPill),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// A started timer: the countdown and Stop, or "Time's up" and OK. While
/// alerts are off, it says so and offers to turn them on.
class _TimerCard extends StatelessWidget {
  const _TimerCard({
    super.key,
    required this.up,
    required this.clock,
    required this.length,
    required this.onClear,
    this.askAlerts = false,
    this.onAlertsOff,
  });

  final bool up;
  final String clock;
  final String length;
  final VoidCallback onClear;

  /// The system prompt was never shown: "Turn on", else "Settings".
  final bool askAlerts;

  /// Null while alerts reach a locked phone.
  final VoidCallback? onAlertsOff;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l = context.l10n;
    final ink = up ? t.accentText : t.ink;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: up ? t.accentTint : t.surf,
        borderRadius: BorderRadius.circular(rTile),
        border: Border.all(color: up ? t.accent : t.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                up ? Icons.alarm_on_rounded : Icons.timer_outlined,
                size: 22,
                color: ink,
              ),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  up ? l.cookingTimerUp : clock,
                  style: AppType.display(30, color: ink),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(length, style: AppType.ui(14, color: t.ink2)),
          const SizedBox(height: 12),
          SoftPillButton(
            key: const ValueKey('cooking-timer-clear'),
            icon: up ? Icons.check_rounded : Icons.stop_rounded,
            label: up ? l.cookingTimerDismiss : l.cookingTimerStop,
            semanticLabel: up ? null : l.cookingTimerStopLabel(length),
            tone: up ? SoftPillTone.accent : SoftPillTone.neutral,
            onTap: onClear,
          ),
          if (onAlertsOff case final turnOn? when !up) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(Icons.notifications_off_outlined, size: 16, color: t.ink2),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l.cookingAlertsOff,
                    style: AppType.ui(13, color: t.ink2),
                  ),
                ),
              ],
            ),
            EatovaTextAction(
              buttonKey: const ValueKey('cooking-alerts-on'),
              label: askAlerts ? l.cookingAlertsTurnOn : l.cookingAlertsSettings,
              onTap: turnOn,
            ),
          ],
        ],
      ),
    );
  }
}

Future<void> _quiet(Future<void> future) => future.catchError((Object _) {});
