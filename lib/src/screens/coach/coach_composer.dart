part of 'coach_chat_screen.dart';

// ---------------------------------------------------------------------------
// Composer capsule ([FieldCapsule]: field / fieldFocus, no ring): attach,
// text, mic, send tile. A tappable counter of today's questions sits above
// it once the server's limit is known.
// ---------------------------------------------------------------------------

/// Client mirror of the coach-chat input cap, in UTF-16 code units.
///
/// `preFilter` refuses anything longer with a 413 (`MAX_INPUT_CHARS`,
/// supabase/functions/coach-chat/prefilter.ts) — and by then the composer has
/// already cleared the field, so the message exists only as a bubble (P5-03).
/// NOT a second definition: `test/repo_rules_test.dart` reads the TS file and
/// fails the moment the two numbers drift.
const int kCoachMaxInputChars = 1000;

/// Second half of the same server cap: the UTF-8 belt in
/// `handler.ts` (`MAX_INPUT_BYTES`), pinned by the same rule.
///
/// A UTF-16 code unit costs at most 3 UTF-8 bytes, so [kCoachMaxInputChars]
/// already keeps every draft under 3000 bytes and this belt never fires on its
/// own. It is mirrored anyway because the server checks BOTH: dropping it here
/// would make the client cap the looser of the two the day either number moves.
const int kCoachMaxInputBytes = 4000;

/// From which draft length the length counter appears. A permanent counter
/// would nag on every three-word question; the last tenth is where the cap
/// becomes relevant.
const int _lengthHintFrom = kCoachMaxInputChars - 100;

/// Keeps the draft inside the server's input cap instead of letting the user
/// discover it as a 413 with an emptied field. Counts UTF-16 units and bytes
/// like the server, not graphemes (see [TextLengthLimit]).
///
/// Rejects instead of truncating, like the gram fields: a silently cut
/// question is sent as half a sentence, and the tail is gone either way. An
/// edit that reduces the overflow still passes, so a draft filled past the cap
/// by dictation (which writes the controller directly) can be shortened.
const TextLengthLimit _coachInputLimit = TextLengthLimit(
  kCoachMaxInputChars,
  maxUtf8Bytes: kCoachMaxInputBytes,
  truncate: false,
);

class _Composer extends StatefulWidget {
  const _Composer({
    required this.controller,
    required this.focus,
    required this.enabled,
    required this.canSend,
    required this.quota,
    this.counterHidden = false,
    required this.draft,
    required this.listening,
    required this.dictationLanguage,
    required this.onSubmit,
    required this.onMic,
    required this.onDictationLanguage,
    required this.onAttach,
    required this.onQuotaTap,
    this.onUpgrade,
  });

  final TextEditingController controller;
  final FocusNode focus;

  /// Typing allowed (session loaded, quota left).
  final bool enabled;

  /// Actions allowed (additionally: no send in flight).
  final bool canSend;

  /// Today's questions as the server reported them; null while unknown.
  final ChatQuotaSnapshot? quota;

  /// The command menu is open: it names each command's cost and needs the
  /// height on a small screen with the keyboard up.
  final bool counterHidden;
  final String draft;
  final bool listening;

  /// Language of the running dictation; the pill shows while [listening].
  final DictationLanguage dictationLanguage;
  final VoidCallback onSubmit;
  final VoidCallback onMic;
  final VoidCallback onDictationLanguage;
  final VoidCallback onAttach;
  final VoidCallback onQuotaTap;

  /// Opens Premium; set at 0 questions left on Free, where it takes the
  /// counter's place (docs/PREMIUM.md 4.5).
  final VoidCallback? onUpgrade;

  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  late bool _focused = widget.focus.hasFocus;

  @override
  void initState() {
    super.initState();
    widget.focus.addListener(_handleFocusChange);
  }

  @override
  void dispose() {
    widget.focus.removeListener(_handleFocusChange);
    super.dispose();
  }

  void _handleFocusChange() {
    if (_focused != widget.focus.hasFocus) {
      setState(() => _focused = widget.focus.hasFocus);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final hasText = widget.draft.trim().isNotEmpty;
    // 2026-10-22: always on once the server named its limit, so every
    // question visibly costs one. An unknown quota and an assumed limit
    // show no number: either would be a claim the app cannot back.
    final quota = widget.quota;
    final counter =
        quota != null && !quota.limitAssumed && !widget.counterHidden
        ? quota
        : null;
    final upgrade = counter != null && counter.remaining <= 0
        ? widget.onUpgrade
        : null;
    // P5-06b: a count of 0 stopped meaning "blocked". A merely ASSUMED daily
    // limit keeps the composer typable (fail-open, P5-06), and only [enabled]
    // carries that decision — so the placeholder names the limit exactly when
    // the limit is what locks the field, instead of contradicting it.
    final limitReached =
        (quota?.remaining ?? ChatQuotaSnapshot.standardTageslimit) <= 0 &&
        !widget.enabled;
    // P5-03: the draft is over the server's cap. Reachable only from code
    // (dictation writes the controller directly); typing stops at the cap.
    final overLimit = !_coachInputLimit.fits(widget.draft);
    final showLengthHint = widget.draft.length >= _lengthHintFrom || overLimit;
    // With the floating tab bar below, the capsule sits right on the bar's
    // band (the design's dock line); on the keyboard it keeps a small gap.
    final onBand = MediaQuery.paddingOf(context).bottom > 0;
    // No viewInsets padding: the home scaffold uses
    // `resizeToAvoidBottomInset: true`, so the keyboard is already accounted
    // for.
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (upgrade != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                _kShellInset,
                0,
                _kShellInset,
                8,
              ),
              child: Center(
                child: SoftPillButton(
                  key: const ValueKey('coach-composer-upgrade'),
                  icon: AppIcons.workspacePremium,
                  label: l10n.coachComposerUpgrade,
                  onTap: upgrade,
                ),
              ),
            )
          else if (counter != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: _kShellInset),
              child: _QuotaHint(
                remaining: counter.remaining.clamp(0, counter.dailyLimit),
                limit: counter.dailyLimit,
                onTap: widget.onQuotaTap,
              ),
            ),
          if (showLengthHint)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: _kShellInset),
              child: _LengthHint(used: widget.draft.length),
            ),
          // A 56 px capsule 14 px from the screen edges, flush with the tab
          // bar (the content above keeps the 20 px inset).
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppNavBar.sideGap),
            child: FieldCapsule(
              focused: _focused,
              shape: SheetFieldShape.pill,
              constraints: const BoxConstraints(minHeight: 56, maxHeight: 160),
              padding: const EdgeInsets.all(6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: <Widget>[
                  // Plain: the capsule carries the fill.
                  AppIconButton(
                    key: const ValueKey('coach-attach'),
                    icon: AppIcons.add,
                    tone: IconButtonTone.plain,
                    onTap: widget.canSend ? widget.onAttach : null,
                    semanticLabel: l10n.coachAttachSemanticLabel,
                  ),
                  const SizedBox(width: 2),
                  Expanded(
                    child: TextField(
                      key: const ValueKey('coach-input'),
                      cursorOpacityAnimates: false,
                      controller: widget.controller,
                      focusNode: widget.focus,
                      enabled: widget.enabled,
                      // Dictation streams into the field; typing would race it.
                      readOnly: widget.listening,
                      maxLines: 5,
                      minLines: 1,
                      // No `maxLength`: it would hang Flutter's own counter
                      // under the capsule AND enforce the cap in grapheme
                      // clusters, which is not how the server counts.
                      inputFormatters: const <TextInputFormatter>[
                        _coachInputLimit,
                      ],
                      textInputAction: TextInputAction.newline,
                      textCapitalization: TextCapitalization.sentences,
                      style: AppType.ui(16, color: t.ink, height: 1.25),
                      cursorColor: t.accent,
                      decoration: InputDecoration(
                        // All four borders AND `filled` are needed: the app's
                        // inputDecorationTheme fills and outlines fields, so
                        // setting only `border` would leave a second boxed
                        // field inside the capsule (same as SheetField).
                        filled: false,
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        disabledBorder: InputBorder.none,
                        isCollapsed: true,
                        // 12 + 20 + 12 = 44: one line sits centred in the
                        // 56 px capsule next to the 44 px buttons.
                        contentPadding: const EdgeInsets.symmetric(
                          vertical: 12,
                          horizontal: 6,
                        ),
                        // C8: the placeholder names the AI — in a running
                        // chat the composer is the only always-visible spot.
                        // A wrapped hint must not reserve five input lines on
                        // narrow screens while the actual draft is one line.
                        hintMaxLines: 1,
                        hintText: limitReached
                            ? l10n.coachComposerHintLimitReached
                            : widget.listening
                            ? l10n.coachComposerHintListening
                            : l10n.coachComposerHintDefault,
                        // ink2, not the design's ink3: on the field fill ink3
                        // stays under 4.5:1.
                        hintStyle: AppType.ui(16, color: t.ink2, height: 1.25),
                      ),
                    ),
                  ),
                  // The `eatova/speech` channel is implemented in the iOS
                  // runner only; elsewhere the button could merely fail.
                  // `defaultTargetPlatform` honours the test override.
                  if (defaultTargetPlatform == TargetPlatform.iOS) ...<Widget>[
                    if (widget.listening)
                      _DictationLanguagePill(
                        language: widget.dictationLanguage,
                        onTap: widget.onDictationLanguage,
                      ),
                    const SizedBox(width: 2),
                    _MicButton(
                      // Dictating is typing by voice: allowed while an answer
                      // is in flight, and stopping is never blocked.
                      enabled: widget.enabled || widget.listening,
                      listening: widget.listening,
                      onTap: widget.onMic,
                    ),
                  ],
                  const SizedBox(width: 2),
                  _SendButton(
                    active: hasText,
                    // `!overLimit`: sending would spend both rate-limit
                    // windows on a guaranteed 413 and clear the field on the
                    // way. While listening a tap only finishes the dictation.
                    enabled:
                        widget.listening ||
                        (widget.canSend && hasText && !overLimit),
                    finishesDictation: widget.listening,
                    onTap: widget.onSubmit,
                  ),
                ],
              ),
            ),
          ),
          SizedBox(height: onBand ? 0 : 8),
        ],
      ),
    );
  }
}

/// Subtle counter of today's coach questions above the composer ("3/5 heute
/// frei"); the dot appears once only 2 or fewer are left. Tapping opens the
/// quota sheet.
class _QuotaHint extends StatelessWidget {
  const _QuotaHint({
    required this.remaining,
    required this.limit,
    required this.onTap,
  });

  final int remaining;
  final int limit;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final shape = StadiumBorder(side: BorderSide(color: t.line));
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Center(
        child: Material(
          key: const ValueKey('coach-quota-hint'),
          color: t.surf,
          shape: shape,
          child: InkWell(
            customBorder: shape,
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  if (remaining <= 2) ...<Widget>[
                    Container(
                      width: 6,
                      height: 6,
                      decoration:
                          BoxDecoration(shape: BoxShape.circle, color: t.lime),
                    ),
                    const SizedBox(width: 7),
                  ],
                  Flexible(
                    child: Text(
                      l10n.coachQuotaCounter(remaining, limit),
                      // "3/5" reads as a fraction; the label says it.
                      semanticsLabel:
                          l10n.coachQuotaCounterLabel(remaining, limit),
                      style: AppType.ui(
                        12,
                        weight: FontWeight.w600,
                        color: t.ink2,
                        tabular: true,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Length counter above the composer — the visible reason for a keystroke that
/// does not arrive.
///
/// Shows only near the cap (see [_lengthHintFrom]) and switches to a warning
/// wording once the cap is reached: at that point [_coachInputLimit] starts
/// refusing input and the send tile goes quiet, which without a stated reason
/// looks like a broken field. The state is in the WORDING, not only in the
/// colour, so it survives colour blindness and a screen reader.
class _LengthHint extends StatelessWidget {
  const _LengthHint({required this.used});

  /// Draft length in UTF-16 code units — the unit the server counts in.
  final int used;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final reached = used >= kCoachMaxInputChars;
    return Padding(
      padding: const EdgeInsets.only(right: 6, bottom: 6),
      child: Align(
        alignment: Alignment.centerRight,
        child: Semantics(
          // The counter changes while typing and is never focused, so without
          // a live region a screen reader never learns the field is full.
          liveRegion: true,
          child: Text(
            reached
                ? l10n.coachComposerLengthReached(kCoachMaxInputChars)
                : l10n.coachComposerLengthHint(used, kCoachMaxInputChars),
            key: const ValueKey('coach-length-hint'),
            style: AppType.ui(
              12,
              weight: FontWeight.w600,
              color: reached ? t.warning : t.ink2,
              tabular: true,
            ),
          ),
        ),
      ),
    );
  }
}

/// Mic button in the composer: a plain glyph like the attach button, and
/// while [listening] an accent toggle with the filled mic and a soft ring
/// pulsing behind it (static under "reduce motion").
///
/// The listening state uses the accent tones, NOT `lime`: as a stroke on the
/// light composer capsule `lime` reaches only ~1.2:1, so the mic would look
/// idle while recording.
class _MicButton extends StatefulWidget {
  const _MicButton({
    required this.enabled,
    required this.listening,
    required this.onTap,
  });

  final bool enabled;
  final bool listening;
  final VoidCallback onTap;

  @override
  State<_MicButton> createState() => _MicButtonState();
}

class _MicButtonState extends State<_MicButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncPulse();
  }

  @override
  void didUpdateWidget(covariant _MicButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncPulse();
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  void _syncPulse() {
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (widget.listening && !reduce) {
      if (!_pulse.isAnimating) _pulse.repeat();
    } else {
      if (_pulse.isAnimating) _pulse.stop();
      _pulse.value = 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return AppIconButton(
      key: const ValueKey('coach-mic'),
      // A toggle: the state is also in the name, so a screen reader user
      // learns that recording is running.
      semanticLabel: widget.listening
          ? l10n.coachMicLabelListening
          : l10n.coachMicLabelIdle,
      tone: widget.listening ? IconButtonTone.accent : IconButtonTone.plain,
      selected: widget.listening,
      onTap: widget.enabled ? widget.onTap : null,
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          if (widget.listening && !reduce)
            RepaintBoundary(
              child: AnimatedBuilder(
                animation: _pulse,
                builder: (_, __) {
                  final v = _pulse.value;
                  return Container(
                    width: 24 + 14 * v,
                    height: 24 + 14 * v,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: t.accent.withValues(alpha: 0.5 * (1 - v)),
                        width: 1.5,
                      ),
                    ),
                  );
                },
              ),
            ),
          StateIcon(AppIcons.mic, on: widget.listening),
        ],
      ),
    );
  }
}

/// DE/EN switch next to the mic while listening (spec D5). Apple recognizes
/// one language per session, so a German speaker with an English UI switches
/// here; a tap restarts only the running dictation.
class _DictationLanguagePill extends StatelessWidget {
  const _DictationLanguagePill({required this.language, required this.onTap});

  final DictationLanguage language;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    String name(DictationLanguage value) => value == DictationLanguage.de
        ? l10n.coachDictationLanguageGerman
        : l10n.coachDictationLanguageEnglish;
    return Semantics(
      key: const ValueKey('coach-dictation-language'),
      button: true,
      label: l10n.coachDictationLanguageLabel(name(language)),
      hint: l10n.coachDictationLanguageSwitchHint(name(language.other)),
      onTap: onTap,
      excludeSemantics: true,
      child: Material(
        color: Colors.transparent,
        shape: const StadiumBorder(),
        child: InkWell(
          onTap: onTap,
          customBorder: const StadiumBorder(),
          // 44 px target around the small pill.
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: t.accentTint,
                  borderRadius: BorderRadius.circular(rPill),
                ),
                child: Text(
                  language == DictationLanguage.de
                      ? l10n.coachDictationLanguageDe
                      : l10n.coachDictationLanguageEn,
                  style: AppType.ui(
                    12,
                    weight: FontWeight.w700,
                    color: t.accentText,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Send button: lit (the view's one primary action) with an up arrow once
/// there is a draft; a faint accent disc while there is none, so it never
/// looks live when dead. A draft that cannot go out (request in flight,
/// over the cap) shows the lit button's "not yet" tint.
class _SendButton extends StatelessWidget {
  const _SendButton({
    required this.active,
    required this.enabled,
    required this.finishesDictation,
    required this.onTap,
  });

  final bool active;
  final bool enabled;

  /// While listening a tap ends the dictation and sends nothing; the name
  /// says so instead of "Send" (R17 D2-M3).
  final bool finishesDictation;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    // While dictating the button finishes it; the hint says that nothing is
    // sent yet. MergeSemantics joins the hint into the button's own node.
    return MergeSemantics(
      child: Semantics(
        hint: finishesDictation ? l10n.coachDictationSendHint : null,
        child: AppIconButton(
          key: const ValueKey('coach-send'),
          icon: AppIcons.arrowUpward,
          semanticLabel: finishesDictation
              ? l10n.coachDictationSendLabel
              : l10n.coachSendLabel,
          tone: active ? IconButtonTone.primary : IconButtonTone.accent,
          onTap: enabled ? onTap : null,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
/// Sheet behind the (i) in the header and behind the empty-state hint.
///
/// C8: the disclosure comes first, the daily quota below it — every message
/// ships a day snapshot (weight, goal, calories, open macros, today's meal
/// names) to a US third party, which was only stated in the privacy policy.
class _CoachInfoSheet extends StatelessWidget {
  const _CoachInfoSheet({
    required this.remaining,
    required this.dailyLimit,
    this.premiumLimit,
    this.onUpgrade,
  });

  final int remaining;
  final int dailyLimit;

  /// On Free with a known plan: the Coach limit Premium gives; null hides
  /// the Premium line.
  final int? premiumLimit;

  /// Opens Premium (after closing the sheet); null shows no button.
  final VoidCallback? onUpgrade;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.82,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
          child: Column(
            key: const ValueKey('coach-info-sheet'),
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              ..._coachInfoDisclosure(context),
              Text(
                l10n.coachInfoLimitBody(
                  remaining,
                  dailyLimit,
                  coachQuotaResetLabel(l10n.localeName),
                ),
                style: AppType.callout(t.ink2),
              ),
              const SizedBox(height: 14),
              _QuotaBar(remaining: remaining, total: dailyLimit),
              if (premiumLimit case final limit?)
                _InfoPremium(limit: limit, onUpgrade: onUpgrade),
            ],
          ),
        ),
      ),
    );
  }
}

/// The info sheets' Premium part on Free: what Premium gives and the way
/// there. Both twins show it alike, after the disclosure and the quota.
class _InfoPremium extends StatelessWidget {
  const _InfoPremium({required this.limit, this.onUpgrade});

  final int limit;
  final VoidCallback? onUpgrade;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final upgrade = onUpgrade;
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            l10n.coachInfoPremiumLine(limit),
            key: const ValueKey('coach-info-premium'),
            style: AppType.callout(t.ink2),
          ),
          if (upgrade != null) ...<Widget>[
            const SizedBox(height: 12),
            SoftPillButton(
              key: const ValueKey('coach-info-upgrade'),
              icon: AppIcons.workspacePremium,
              label: l10n.planLimitUpgrade,
              onTap: () {
                Navigator.of(context).pop();
                upgrade();
              },
            ),
          ],
        ],
      ),
    );
  }
}

/// The C8 disclosure both info sheets open with, in this order: title,
/// intro, what every question sends (a level-2 section with a bullet list),
/// provider, report hint, then the limit section's heading. The callers add
/// the limit line itself (with or without numbers).
List<Widget> _coachInfoDisclosure(BuildContext context) {
  final t = context.t;
  final l10n = context.l10n;
  return <Widget>[
    // No own drag handle: showEatovaSheet sets showDragHandle.
    SheetTitle(l10n.coachTitle),
    const SizedBox(height: kSpace8),
    Text(l10n.coachInfoIntro, style: AppType.callout(t.ink2)),
    const SizedBox(height: kSpace24),
    SectionHeading(title: l10n.coachInfoDataLabel),
    const SizedBox(height: kSpace12),
    BulletList(
      items: <String>[
        l10n.coachInfoBulletWeight,
        l10n.coachInfoBulletMacros,
        l10n.coachInfoBulletMeals,
        l10n.coachInfoBulletPlan,
        l10n.foodPrefsCoachInfoBullet,
      ],
      style: AppType.callout(t.ink),
      gap: 10,
    ),
    const SizedBox(height: kSpace16),
    Text(l10n.coachInfoProvider, style: AppType.callout(t.ink2)),
    const SizedBox(height: kSpace12),
    Text(l10n.coachReportHint, style: AppType.callout(t.ink2)),
    const SizedBox(height: kSpace20),
    Container(height: 1, color: t.line),
    const SizedBox(height: kSpace20),
    SectionHeading(title: l10n.coachInfoLimitLabel),
    const SizedBox(height: kSpace8),
  ];
}

// ---------------------------------------------------------------------------
class _QuotaBar extends StatelessWidget {
  const _QuotaBar({required this.remaining, required this.total});

  final int remaining;
  final int total;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final pct = total == 0 ? 0.0 : remaining / total;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        ClipRRect(
          borderRadius: BorderRadius.circular(rPill),
          child: Stack(
            children: <Widget>[
              Container(height: 6, color: t.tile),
              FractionallySizedBox(
                widthFactor: pct.clamp(0.0, 1.0),
                child: Container(
                  height: 6,
                  decoration: BoxDecoration(color: t.accent),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: kSpace8),
        Text('$remaining / $total', style: AppType.numeric(14, color: t.ink)),
      ],
    );
  }
}
