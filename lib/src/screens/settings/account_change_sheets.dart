import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../auth/auth_repository.dart';
import '../../l10n/l10n.dart';
import '../../services/secure_screen.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/design/design.dart';
import 'account_change_messages.dart';
import 'settings_controls.dart';

// ---------------------------------------------------------------------------
// The two account changes in the settings.
//
// SHEETS, NOT ROUTES: both flows are short and self-contained (two fields, one
// code) and leave the user exactly where they were, so they use the same
// building blocks as the delete confirmation (`showEatovaSheet` +
// [SheetScaffold] + [SheetField]). A route with header and back arrow would
// fake a depth these flows do not have.
//
// Both sheets carry TWO steps in ONE sheet: step two needs step one, and a
// sheet that closes and immediately reopens looks like an error.
//
// [SecureScreenGuard] wraps both — codes and mail addresses do not belong in
// the app-switcher thumbnail. The guard is ref-counted, so nesting it under
// the settings screen guard is free.
//
// BOTH SHEETS ARE GUARDED AGAINST AN ACCIDENTAL DISMISS (P4-06): everything
// these flows achieved lives in the sheet's State, and the codes behind it are
// SERVER-SIDE spent — GoTrue burns a confirmed code, and only two mails go out
// per hour. A swipe or a tap beside the sheet (easy to hit while dismissing
// the keyboard) therefore asks first; see [_fragAbbruch] and
// [SheetDismissGuard]. `dragHandle: false` is part of that: a pull on
// Material's own handle pops past `PopScope`, so the sheets draw a
// [SheetHandle] themselves.
// ---------------------------------------------------------------------------

/// Opens the password change. Returns `true` only when the password was
/// actually set; only then does the caller show its confirmation.
Future<bool> showPasswordChangeSheet(
  BuildContext context, {
  required AuthRepository authRepository,
  String? email,
}) async {
  final erfolg = await showEatovaSheet<bool>(
    context,
    SecureScreenGuard(
      child: _PasswordChangeSheet(
        key: const ValueKey<String>('password-change-sheet'),
        authRepository: authRepository,
        email: email,
      ),
    ),
    // See the file header: the sheet draws its own handle so the drag guard
    // sees every dismiss.
    dragHandle: false,
  );
  return erfolg ?? false;
}

/// Opens the email change. [currentEmail] is required: the first of the two
/// codes is verified against the PREVIOUS address.
Future<bool> showEmailChangeSheet(
  BuildContext context, {
  required AuthRepository authRepository,
  required String currentEmail,
}) async {
  final erfolg = await showEatovaSheet<bool>(
    context,
    SecureScreenGuard(
      child: _EmailChangeSheet(
        key: const ValueKey<String>('email-change-sheet'),
        authRepository: authRepository,
        currentEmail: currentEmail,
      ),
    ),
    dragHandle: false,
  );
  return erfolg ?? false;
}

/// Asks before an unfinished code flow is thrown away (P4-06).
///
/// `true` = discard. [codeVerbraucht] switches to the sharper wording of the
/// email flow, where the FIRST code is already confirmed: GoTrue burns a
/// confirmed code, so that half cannot be repeated with the mail in the inbox.
///
/// `barrierDismissible` stays true — a tap outside means "keep going", and the
/// dialog's own barrier swallows it, so the sheet below never sees it.
Future<bool> _fragAbbruch(
  BuildContext context, {
  required bool codeVerbraucht,
}) async {
  final t = context.t;
  final l10n = context.l10n;
  final abbrechen = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      key: const ValueKey<String>('account-change-discard-dialog'),
      backgroundColor: t.surf,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(rSheet),
      ),
      title: Text(
        l10n.settingsAccountDiscardTitle,
        style: AppType.display(19, color: t.ink),
      ),
      content: Text(
        codeVerbraucht
            ? l10n.settingsAccountDiscardBodyConfirmed
            : l10n.settingsAccountDiscardBody,
        style: AppType.ui(13, color: t.ink2, height: 1.4),
      ),
      actions: <Widget>[
        TextButton(
          key: const ValueKey<String>('account-change-discard-keep'),
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(l10n.settingsAccountDiscardKeep),
        ),
        TextButton(
          key: const ValueKey<String>('account-change-discard-confirm'),
          // Destructive red is the one color the theme may not decide.
          style: TextButton.styleFrom(foregroundColor: t.danger),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(l10n.settingsAccountDiscardConfirm),
        ),
      ],
    ),
  );
  return abbrechen ?? false;
}

/// The shell both sheets wear: handle, dismiss guard and [PopScope] around the
/// [SheetScaffold] (P4-06).
///
/// [verbraucht] means "the flow already cost something a retry cannot get
/// back" — a requested or confirmed code. Only then does closing ask.
class _AbbruchGuard extends StatefulWidget {
  const _AbbruchGuard({
    required this.verbraucht,
    required this.codeVerbraucht,
    required this.child,
  });

  final bool verbraucht;

  /// A code that is already CONFIRMED (email flow, step two) — sharper wording.
  final bool codeVerbraucht;

  final Widget child;

  @override
  State<_AbbruchGuard> createState() => _AbbruchGuardState();
}

class _AbbruchGuardState extends State<_AbbruchGuard> {
  /// Guards every intercepted dismiss (barrier tap and system back via
  /// [PopScope], drag via [SheetDismissGuard]) so repeated attempts do not
  /// stack dialogs.
  bool _dialogOffen = false;

  Future<void> _frage() async {
    if (_dialogOffen) return;
    _dialogOffen = true;
    final abbrechen =
        await _fragAbbruch(context, codeVerbraucht: widget.codeVerbraucht);
    _dialogOffen = false;
    if (!mounted || !abbrechen) return;
    // No result: an aborted change is not a successful one.
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope<bool>(
      canPop: !widget.verbraucht,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        unawaited(_frage());
      },
      child: SheetDismissGuard(
        active: widget.verbraucht,
        onDismissAttempt: _frage,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            // Material's handle also carries the "dismiss" semantics action,
            // and that goes away with `dragHandle: false` — so the sheet's own
            // handle has to offer it, routed through `maybePop` and therefore
            // through the confirmation. Without it a screen-reader user would
            // have no way out of the sheet at all.
            Semantics(
              button: true,
              label: MaterialLocalizations.of(context).modalBarrierDismissLabel,
              onTap: () => Navigator.of(context).maybePop(),
              child: const SheetHandle(),
            ),
            Flexible(child: widget.child),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Flow 1 — change password
// ---------------------------------------------------------------------------

enum _PasswortSchritt { codeAnfordern, codeUndPasswort }

class _PasswordChangeSheet extends StatefulWidget {
  const _PasswordChangeSheet({
    super.key,
    required this.authRepository,
    this.email,
  });

  final AuthRepository authRepository;

  /// Display only: GoTrue sends the code to the stored address by itself.
  final String? email;

  @override
  State<_PasswordChangeSheet> createState() => _PasswordChangeSheetState();
}

class _PasswordChangeSheetState extends State<_PasswordChangeSheet> {
  final TextEditingController _code = TextEditingController();
  final TextEditingController _neu = TextEditingController();
  final TextEditingController _wiederholung = TextEditingController();

  _PasswortSchritt _schritt = _PasswortSchritt.codeAnfordern;
  bool _busy = false;
  String? _fehler;
  String? _codeFehler;
  String? _neuFehler;
  String? _wiederholungFehler;

  @override
  void dispose() {
    _code.dispose();
    _neu.dispose();
    _wiederholung.dispose();
    super.dispose();
  }

  Future<void> _codeAnfordern() async {
    // Double-tap latch here AND on `actionEnabled`: the button lock only
    // takes effect with the next frame.
    if (_busy) return;
    setState(() {
      _busy = true;
      _fehler = null;
    });
    try {
      await widget.authRepository.startPasswordChange();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _fehler = accountChangeErrorMessage(error, context.l10n);
      });
      return;
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _schritt = _PasswortSchritt.codeUndPasswort;
    });
  }

  Future<void> _passwortSetzen() async {
    if (_busy) return;
    final l10n = context.l10n;
    final code = _code.text.trim();
    final neu = _neu.text;
    final wiederholung = _wiederholung.text;

    // Catch everything the app can know itself: a submit that predictably
    // fails server-side also burns the code (GoTrue accepts a nonce once).
    final codeFehler = isAccountCode(code) ? null : kAccountCodeInvalid(l10n);
    final neuFehler = neu.length < kAccountMinPasswordLength
        ? kAccountPasswordTooShort(l10n)
        : null;
    final wiederholungFehler = neuFehler == null && wiederholung != neu
        ? kAccountPasswordMismatch(l10n)
        : null;

    if (codeFehler != null || neuFehler != null || wiederholungFehler != null) {
      setState(() {
        _fehler = null;
        _codeFehler = codeFehler;
        _neuFehler = neuFehler;
        _wiederholungFehler = wiederholungFehler;
      });
      return;
    }

    setState(() {
      _busy = true;
      _fehler = null;
      _codeFehler = null;
      _neuFehler = null;
      _wiederholungFehler = null;
    });
    try {
      await widget.authRepository
          .confirmPasswordChange(code: code, newPassword: neu);
    } catch (error) {
      if (!mounted) return;
      // Do not clear the fields: a mistyped code does not invalidate the
      // password the user typed correctly.
      setState(() {
        _busy = false;
        _fehler = accountChangeErrorMessage(error, context.l10n);
      });
      return;
    }
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final adresse = widget.email;
    final ersterSchritt = _schritt == _PasswortSchritt.codeAnfordern;

    return _AbbruchGuard(
      // From step two on a code is out in the world and the mail quota is
      // down one; losing that to a stray swipe costs a new mail at best.
      verbraucht: !ersterSchritt,
      codeVerbraucht: false,
      child: SheetScaffold(
        title: l10n.settingsChangePasswordTitle,
        subtitle: ersterSchritt
            ? (adresse == null
                ? l10n.settingsPasswordChangeCodeSentDefault
                : l10n.settingsPasswordChangeCodeSentTo(adresse))
            : l10n.settingsPasswordChangeStep2Subtitle,
        actionLabel: _aktionsBeschriftung(l10n, ersterSchritt),
        actionEnabled: !_busy,
        onAction: ersterSchritt ? _codeAnfordern : _passwortSetzen,
        children: <Widget>[
          if (!ersterSchritt) ...<Widget>[
            _CodeFeld(
              fieldKey: const ValueKey<String>('password-change-code'),
              label: l10n.settingsPasswordChangeCodeFieldLabel,
              adresse: adresse,
              controller: _code,
              enabled: !_busy,
              errorText: _codeFehler,
            ),
            SheetField(
              key: const ValueKey<String>('password-change-new'),
              label: l10n.settingsPasswordChangeNewLabel,
              hint: l10n.settingsPasswordChangeNewHint,
              obscure: true,
              controller: _neu,
              enabled: !_busy,
              errorText: _neuFehler,
            ),
            SheetField(
              key: const ValueKey<String>('password-change-repeat'),
              label: l10n.settingsPasswordChangeRepeatLabel,
              hint: l10n.settingsPasswordChangeRepeatHint,
              obscure: true,
              controller: _wiederholung,
              enabled: !_busy,
              errorText: _wiederholungFehler,
            ),
          ],
          if (_fehler != null)
            _FehlerNotiz(
              noteKey: const ValueKey<String>('password-change-error'),
              text: _fehler!,
            ),
        ],
      ),
    );
  }

  String _aktionsBeschriftung(AppLocalizations l10n, bool ersterSchritt) {
    if (_busy) {
      return ersterSchritt
          ? l10n.settingsPasswordChangeRequestingCta
          : l10n.settingsPasswordChangeSavingCta;
    }
    // Deliberately not the same label as the row that opened this sheet and
    // the sheet title: three identical labels in one tree are ambiguous for
    // screen readers and tests alike.
    return ersterSchritt
        ? l10n.settingsPasswordChangeRequestCta
        : l10n.settingsPasswordChangeSubmitCta;
  }
}

// ---------------------------------------------------------------------------
// Flow 2 — change email address
// ---------------------------------------------------------------------------

enum _MailSchritt { adresse, codes }

class _EmailChangeSheet extends StatefulWidget {
  const _EmailChangeSheet({
    super.key,
    required this.authRepository,
    required this.currentEmail,
  });

  final AuthRepository authRepository;
  final String currentEmail;

  @override
  State<_EmailChangeSheet> createState() => _EmailChangeSheetState();
}

class _EmailChangeSheetState extends State<_EmailChangeSheet> {
  final TextEditingController _adresse = TextEditingController();
  final TextEditingController _codeAlt = TextEditingController();
  final TextEditingController _codeNeu = TextEditingController();

  _MailSchritt _schritt = _MailSchritt.adresse;
  String _zieladresse = '';
  bool _busy = false;

  /// Which of the two codes already passed. GoTrue burns a confirmed code, so
  /// without remembering this a typo in the SECOND code would make the whole
  /// flow unrecoverable.
  bool _altBestaetigt = false;
  bool _neuBestaetigt = false;

  String? _adressFehler;
  String? _fehlerAlt;
  String? _fehlerNeu;

  @override
  void dispose() {
    _adresse.dispose();
    _codeAlt.dispose();
    _codeNeu.dispose();
    super.dispose();
  }

  Future<void> _codesAnfordern() async {
    if (_busy) return;
    final l10n = context.l10n;
    final ziel = _adresse.text.trim();
    if (!isPlausibleAccountEmail(ziel)) {
      setState(() => _adressFehler = kAccountEmailInvalid(l10n));
      return;
    }
    if (ziel.toLowerCase() == widget.currentEmail.trim().toLowerCase()) {
      setState(() => _adressFehler = kAccountEmailUnchanged(l10n));
      return;
    }

    setState(() {
      _busy = true;
      _adressFehler = null;
    });
    try {
      await widget.authRepository.startEmailChange(ziel);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _adressFehler = accountChangeErrorMessage(error, context.l10n);
      });
      return;
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _zieladresse = ziel;
      _schritt = _MailSchritt.codes;
    });
  }

  Future<void> _adresseBestaetigen() async {
    if (_busy) return;
    final l10n = context.l10n;
    final codeAlt = _codeAlt.text.trim();
    final codeNeu = _codeNeu.text.trim();

    // A single code changes nothing and would only be consumed, so no call
    // goes out without BOTH.
    final fehlerAlt = _altBestaetigt || isAccountCode(codeAlt)
        ? null
        : kAccountCodeInvalid(l10n);
    final fehlerNeu = _neuBestaetigt || isAccountCode(codeNeu)
        ? null
        : kAccountCodeInvalid(l10n);
    if (fehlerAlt != null || fehlerNeu != null) {
      setState(() {
        _fehlerAlt = fehlerAlt;
        _fehlerNeu = fehlerNeu;
      });
      return;
    }

    setState(() {
      _busy = true;
      _fehlerAlt = null;
      _fehlerNeu = null;
    });

    if (!_altBestaetigt) {
      try {
        await widget.authRepository.confirmEmailChange(
          email: widget.currentEmail,
          code: codeAlt,
        );
      } catch (error) {
        if (!mounted) return;
        setState(() {
          _busy = false;
          _fehlerAlt = accountChangeErrorMessage(error, context.l10n);
        });
        return;
      }
      if (!mounted) return;
      setState(() => _altBestaetigt = true);
    }

    if (!_neuBestaetigt) {
      try {
        await widget.authRepository.confirmEmailChange(
          email: _zieladresse,
          code: codeNeu,
        );
      } catch (error) {
        if (!mounted) return;
        setState(() {
          _busy = false;
          _fehlerNeu = accountChangeErrorMessage(error, context.l10n);
        });
        return;
      }
      if (!mounted) return;
      setState(() => _neuBestaetigt = true);
    }

    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final ersterSchritt = _schritt == _MailSchritt.adresse;

    return _AbbruchGuard(
      // Step two holds two mailed codes — and possibly one already CONFIRMED
      // and thereby burned. That is the state the file's own comment on
      // [_altBestaetigt] warns about; a swipe must not take it.
      verbraucht: !ersterSchritt,
      codeVerbraucht: _altBestaetigt || _neuBestaetigt,
      child: SheetScaffold(
        title: l10n.settingsChangeEmailTitle,
        subtitle: ersterSchritt
            ? l10n.settingsEmailChangeStep1Subtitle(widget.currentEmail)
            : l10n.settingsEmailChangeStep2Subtitle,
        actionLabel: _aktionsBeschriftung(l10n, ersterSchritt),
        actionEnabled: !_busy,
        onAction: ersterSchritt ? _codesAnfordern : _adresseBestaetigen,
        children: <Widget>[
          if (ersterSchritt)
            SheetField(
              key: const ValueKey<String>('email-change-new-address'),
              label: l10n.settingsEmailChangeNewAddressLabel,
              hint: l10n.settingsEmailChangeNewAddressHint,
              controller: _adresse,
              enabled: !_busy,
              keyboardType: TextInputType.emailAddress,
              errorText: _adressFehler,
            )
          else ...<Widget>[
            _CodeFeld(
              fieldKey: const ValueKey<String>('email-change-code-old'),
              label: l10n.settingsEmailChangeOldCodeLabel,
              adresse: widget.currentEmail,
              controller: _codeAlt,
              // A confirmed code is spent: the field stays visible for
              // traceability but inert.
              enabled: !_busy && !_altBestaetigt,
              errorText: _fehlerAlt,
              erledigt: _altBestaetigt,
            ),
            _CodeFeld(
              fieldKey: const ValueKey<String>('email-change-code-new'),
              label: l10n.settingsEmailChangeNewCodeLabel,
              adresse: _zieladresse,
              controller: _codeNeu,
              enabled: !_busy && !_neuBestaetigt,
              errorText: _fehlerNeu,
              erledigt: _neuBestaetigt,
            ),
            SettingsNote(
              key: const ValueKey<String>('email-change-both-hint'),
              l10n.settingsEmailChangeBothCodesHint,
              boxed: true,
            ),
          ],
        ],
      ),
    );
  }

  String _aktionsBeschriftung(AppLocalizations l10n, bool ersterSchritt) {
    if (_busy) {
      return ersterSchritt
          ? l10n.settingsEmailChangeRequestingCta
          : l10n.settingsEmailChangeCheckingCta;
    }
    return ersterSchritt
        ? l10n.settingsEmailChangeRequestCta
        : l10n.settingsEmailChangeSubmitCta;
  }
}

// ---------------------------------------------------------------------------
// Building blocks of this package
// ---------------------------------------------------------------------------

/// A [kAccountCodeLength]-digit field with its address in PLAIN case above.
///
/// Package-local instead of [SheetField], whose label runs through
/// `toUpperCase()`: an upper-cased mail address looks like a different string,
/// and the two-code step depends on telling the addresses apart. [fieldKey]
/// sits on the inner [TextField] so tests can read its controller.
class _CodeFeld extends StatelessWidget {
  const _CodeFeld({
    required this.fieldKey,
    required this.label,
    required this.controller,
    this.adresse,
    this.enabled = true,
    this.errorText,
    this.erledigt = false,
  });

  final Key fieldKey;
  final String label;
  final TextEditingController controller;

  /// The address this particular code went to.
  final String? adresse;

  final bool enabled;
  final String? errorText;

  /// This code is already confirmed - check mark instead of a hint.
  final bool erledigt;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final hatFehler = errorText != null;
    final adresszeile = adresse;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  label.toUpperCase(),
                  style: AppType.eyebrow(t.ink2, size: 9.5),
                ),
              ),
              if (erledigt)
                Icon(Icons.check_circle_rounded, size: 15, color: t.accent),
            ],
          ),
          if (adresszeile != null && adresszeile.isNotEmpty) ...<Widget>[
            const SizedBox(height: 3),
            Text(
              adresszeile,
              style: AppType.ui(12.5, weight: FontWeight.w600, color: t.ink),
            ),
          ],
          const SizedBox(height: 7),
          // [FieldCapsule] carries the fill language (field / fieldFocus /
          // fieldError, shadow, dimmed when disabled); the error line below
          // names the problem. The `Focus` ancestor only observes (cannot
          // take focus, skipped in traversal): `Focus.of` re-renders on every
          // focus change of the descendant field.
          Focus(
            canRequestFocus: false,
            skipTraversal: true,
            includeSemantics: false,
            child: Builder(
              builder: (context) {
                return FieldCapsule(
                  focused: Focus.of(context).hasFocus,
                  error: hatFehler,
                  enabled: enabled,
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: TextField(
                          key: fieldKey,
                          controller: controller,
                          enabled: enabled,
                          // Otherwise the cursor fade animates forever and
                          // `pumpAndSettle` never settles.
                          cursorOpacityAnimates: false,
                          cursorColor: t.accent,
                          keyboardType: TextInputType.number,
                          inputFormatters: <TextInputFormatter>[
                            FilteringTextInputFormatter.digitsOnly,
                            LengthLimitingTextInputFormatter(
                              kAccountCodeLength,
                            ),
                          ],
                          style: AppType.display(
                            18,
                            weight: FontWeight.w700,
                            color: t.ink,
                            letterSpacing: 5,
                          ),
                          decoration: InputDecoration(
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            disabledBorder: InputBorder.none,
                            filled: false,
                            isDense: true,
                            contentPadding:
                                const EdgeInsets.symmetric(vertical: 15),
                            hintText: '••••••••',
                            hintStyle: AppType.ui(
                              14,
                              color: t.ink2,
                              letterSpacing: 5,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          if (hatFehler) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              errorText!,
              style: AppType.ui(11.5, weight: FontWeight.w500, color: t.danger),
            ),
          ],
        ],
      ),
    );
  }
}

/// The collected message at the foot of a sheet: like [SettingsNote], always
/// in the danger tone with the matching glyph.
class _FehlerNotiz extends StatelessWidget {
  const _FehlerNotiz({required this.noteKey, required this.text});

  final Key noteKey;
  final String text;

  @override
  Widget build(BuildContext context) {
    return SettingsNote(
      key: noteKey,
      text,
      tone: context.t.danger,
      icon: Icons.error_outline_rounded,
      boxed: true,
    );
  }
}
