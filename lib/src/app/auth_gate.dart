import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';

import '../auth/auth_repository.dart';
import '../screens/auth_screen.dart';
import '../services/crash_reporter.dart';
import '../services/local_cache.dart';
import '../services/recipe_image_store.dart';
import '../widgets/common/app_snack.dart';

/// Marker for a DELIBERATE sign-out.
///
/// [_AuthGateState._onAuthEvent] sees THAT the identity changed, never why,
/// and route state cannot tell the two apart. Expires after [gueltigkeit] so a
/// stuck attempt cannot silence a REAL session loss.
abstract final class IntentionalSignOut {
  /// Lifetime of a declared intent: enough for the cache purge plus the
  /// `signOut` roundtrip, short enough not to silence the next session.
  static const Duration gueltigkeit = Duration(seconds: 30);

  static DateTime? _markiertAm;

  /// The logout path declares its intent BEFORE calling `signOut` — the auth
  /// event can follow immediately.
  static void mark() => _markiertAm = clock.now();

  /// Withdraws the intent: the sign-out never happened.
  static void clear() => _markiertAm = null;

  /// Reads and CONSUMES the intent — each covers exactly one transition.
  static bool consume() {
    final markiert = _markiertAm;
    _markiertAm = null;
    return markiert != null &&
        clock.now().difference(markiert) < gueltigkeit;
  }
}

/// Purges the personal cache namespace of a replaced user.
///
/// `HomeStore.signOutCleanup` hangs off the sign-out button, which an
/// involuntary session end and a direct A -> B switch never reach (audit M-1).
/// The outbox is kept: pending writes replay on the next login (A2).
Future<void> purgePersonalCacheFor(String userId) async {
  if (userId.isEmpty) return;
  // F1-02: silence the store's OWN instance first — its debounce timer and
  // late live-op callbacks would otherwise write into the slots this purge
  // clears. Independent of whether the second instance can be built.
  //
  // P3-01: AWAITED. Closing only stops writes that have not started; a blob
  // already encrypting in the isolate lands 200-400 ms later, and the second
  // instance cannot order its `remove` behind it (the store's write queue is
  // per instance). `closeInstancesFor` waits for those writes — bounded and
  // never throwing, so it stays outside the catch below.
  await LocalCache.closeInstancesFor(userId);
  try {
    final cache = await LocalCache.create(userId);
    if (cache != null) await purgePersonalCache(cache);
  } catch (e, st) {
    // Best effort: an unpurgeable cache must not block the auth transition,
    // but it is why health data stays behind, so report it.
    unawaited(CrashReporter.capture(e, st, context: 'auth-gate-cache-purge'));
  }
}

/// Split from building the cache so it stays testable without
/// SharedPreferences and the OS keystore.
@visibleForTesting
Future<void> purgePersonalCache(LocalCache cache) =>
    cache.clear(preserveOutbox: true);

class AuthGate extends StatefulWidget {
  const AuthGate({
    super.key,
    required this.authRepository,
    required this.builder,
    this.debugPurgeCache,
  });

  final AuthRepository authRepository;

  /// Test seam for [purgePersonalCacheFor] — `LocalCache.create` returns null
  /// in widget tests. Always null in production.
  @visibleForTesting
  final Future<void> Function(String userId)? debugPurgeCache;

  /// Receives the user plus whether this was a fresh login, so the welcome
  /// animation skips cold starts with a valid session.
  final Widget Function(
    BuildContext context,
    EatovaUser user,
    bool freshLogin,
  ) builder;

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  StreamSubscription<EatovaUser?>? _subscription;
  EatovaUser? _user;
  bool _freshLogin = false;

  @override
  void initState() {
    super.initState();
    final initial = widget.authRepository.currentUser;
    _user = initial;
    // Session restore on app start does not count as a fresh login.
    _freshLogin = false;
    // Finding 5: the recipe photo store is bound to the active user id. Cold
    // start binds the restored user; later transitions go via _onAuthEvent.
    unawaited(RecipeImageStore.instance.setActiveUser(initial?.id));
    _subscription = widget.authRepository.authStateChanges
        .listen(_onAuthEvent, onError: _onAuthStreamError);
  }

  /// The auth stream carries ERRORS, not just values.
  ///
  /// Without `onError` a gotrue error became an unhandled zone error,
  /// triggerable from outside via the BROWSABLE deeplink intent. Report and
  /// carry on — a lost token arrives as a regular `null` event, and a toast
  /// would be externally triggerable. `captureSyncFailure`, not `capture`: a
  /// refresh outage is expected, not an incident.
  void _onAuthStreamError(Object error, StackTrace stack) {
    unawaited(CrashReporter.captureSyncFailure(error, stack,
        context: 'auth-state-stream'));
  }

  void _onAuthEvent(EatovaUser? user) {
    // Finding 5: the gate is the ONE place every auth transition passes.
    // Bound before the mounted check (a teardown event must still purge) and
    // before setState (no frame of the new account sees the old namespace).
    unawaited(RecipeImageStore.instance.setActiveUser(user?.id));
    final previous = _user;
    // Only on a real identity change: a token refresh delivers the same user.
    final identityChanged =
        previous != null && (user == null || user.id != previous.id);
    if (identityChanged) {
      // Same reason as the photo store, for the durable cache: unawaited and
      // before the mounted check, so a teardown event still purges.
      unawaited((widget.debugPurgeCache ?? purgePersonalCacheFor)(previous.id));
    }
    if (!mounted) return;
    final wasLoggedOut = previous == null;
    final isLoggedIn = user != null;

    // D8: AuthGate is MaterialApp.home, so an auth change swapped only that
    // content and anything pushed on top stayed usable, showing data of a dead
    // session. Real identity changes only — a refresh must keep the open view.
    if (identityChanged) {
      // ALWAYS consumed, not only in the notify branch: one intent covers
      // exactly one transition.
      final gewollt = IntentionalSignOut.consume();
      _popToRootRoute();
      // Only the gate knows "signed out" from "session lost", and
      // [IntentionalSignOut] draws that line. The snack runs through the
      // MaterialApp's ScaffoldMessenger and appears once AuthScreen is built.
      if (!isLoggedIn && !gewollt) {
        showAppSnack(
          context,
          'Deine Sitzung ist abgelaufen. Bitte melde dich erneut an.',
          icon: Icons.lock_clock_rounded,
          duration: kSnackError,
        );
      }
    }

    setState(() {
      _user = user;
      if (wasLoggedOut && isLoggedIn) {
        _freshLogin = true;
      } else if (!isLoggedIn) {
        _freshLogin = false;
      }
    });
  }

  /// Pops everything above the root route. `maybeOf` hits the right navigator
  /// because MaterialApp builds `home` into its own navigator's default route;
  /// `isFirst` also covers unnamed routes, and dialogs pop with `null`.
  void _popToRootRoute() {
    Navigator.maybeOf(context)?.popUntil((route) => route.isFirst);
  }

  @override
  void didUpdateWidget(covariant AuthGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.authRepository == widget.authRepository) return;
    _subscription?.cancel();
    _user = widget.authRepository.currentUser;
    // A repository swap is a potential identity change too.
    unawaited(RecipeImageStore.instance.setActiveUser(_user?.id));
    _freshLogin = false;
    _subscription = widget.authRepository.authStateChanges
        .listen(_onAuthEvent, onError: _onAuthStreamError);
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final user = _user;
    if (user == null) {
      return AuthScreen(authRepository: widget.authRepository);
    }
    return widget.builder(context, user, _freshLogin);
  }
}
