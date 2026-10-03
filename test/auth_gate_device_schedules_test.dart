// P2-02: scheduled reminders live in the OS, not in the account's cache. The
// streak reminder (up to 28 dated one-shots, body with the streak count) kept
// firing for whoever used the phone next, because only the sign-out button
// and account deletion cancelled it. Session expiry, a server-side
// revocation, a direct A -> B switch and a cold start without a session went
// through the gate alone, which purged the cache and photos but not the OS
// schedule.
//
// Pinned: every session end the gate sees cancels, a token refresh does not,
// the cancel is ordered before the next account's tree exists, and a throwing
// notification layer neither blocks the transition nor stays unreported.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/main.dart' show EatovaApp;
import 'package:eatova/src/app/auth_gate.dart';
import 'package:eatova/src/auth/auth_repository.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/services/background_sync_scheduler.dart';
import 'package:eatova/src/services/crash_reporter.dart';
import 'package:eatova/src/services/notification_service.dart';
import 'package:eatova/src/services/recipe_image_store.dart';
import 'package:eatova/src/services/rest_alerts.dart';
import 'package:eatova/src/theme/app_theme.dart';

import 'support/harness.dart' show testWidgetsRobust;

class _ScriptedAuthRepository implements AuthRepository {
  _ScriptedAuthRepository(this._user);

  EatovaUser? _user;
  final _controller = StreamController<EatovaUser?>.broadcast();

  void emit(EatovaUser? user) {
    _user = user;
    _controller.add(user);
  }

  void dispose() => _controller.close();

  @override
  EatovaUser? get currentUser => _user;

  @override
  Stream<EatovaUser?> get authStateChanges => _controller.stream;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Records cancel and schedule calls in one ordered log.
class _RecordingNotifications extends NoopNotificationService {
  _RecordingNotifications(this.log, {this.cancelThrows = false});

  final List<String> log;
  final bool cancelThrows;

  @override
  Future<void> cancelAll() async {
    log.add('cancel');
    if (cancelThrows) throw StateError('plugin kaputt');
  }

  @override
  Future<void> scheduleAll(List<NotificationSpec> specs) async =>
      log.add('schedule');
}

/// Also records when the gate opens rest alerts for an account (spec A5).
class _ScopedNotifications extends _RecordingNotifications
    implements RestAlertSessionScope {
  _ScopedNotifications(super.log);

  @override
  void openRestAlerts(String ownerId) => log.add('open $ownerId');
}

class _RecordingScheduler implements BackgroundSyncScheduler {
  _RecordingScheduler({this.cancelThrows = false});

  final bool cancelThrows;
  final List<String> log = [];

  @override
  Future<void> request() async => log.add('request');

  @override
  Future<void> cancel() async {
    log.add('cancel');
    if (cancelThrows) throw StateError('workmanager kaputt');
  }
}

class _NoPhotos extends RecipeImageStore {
  @override
  Future<void> setActiveUser(String? userId, {String? sessionId}) async {}
}

const _a = EatovaUser(id: 'user-a', email: 'a@example.com', sessionId: 's1');
const _b = EatovaUser(id: 'user-b', email: 'b@example.com', sessionId: 's2');

Future<void> _pumpGate(
  WidgetTester tester,
  _ScriptedAuthRepository repository,
  NotificationService notifications, {
  BackgroundSyncScheduler? scheduler,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildEatovaTheme(Brightness.dark),
      locale: const Locale('de'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: AuthGate(
        authRepository: repository,
        notificationService: notifications,
        backgroundSyncScheduler: scheduler,
        debugPurgeCache: (_) async {},
        builder: (context, user, _) => _Home(
          key: ValueKey(user.id),
          user: user,
          notifications: notifications,
          scheduler: scheduler,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Stands in for the home page: plans this account's reminder on mount and
/// requests background sync, as the real page does with a pending outbox.
class _Home extends StatefulWidget {
  const _Home({
    super.key,
    required this.user,
    required this.notifications,
    this.scheduler,
  });

  final EatovaUser user;
  final NotificationService notifications;
  final BackgroundSyncScheduler? scheduler;

  @override
  State<_Home> createState() => _HomeState();
}

class _HomeState extends State<_Home> {
  @override
  void initState() {
    super.initState();
    unawaited(widget.notifications.scheduleAll(const []));
    unawaited(widget.scheduler?.request());
  }

  @override
  Widget build(BuildContext context) =>
      Scaffold(body: Text('home ${widget.user.id}'));
}

void main() {
  setUp(() => RecipeImageStore.instance = _NoPhotos());
  tearDown(RecipeImageStore.resetInstance);

  testWidgets('Session-Verlust verwirft die Erinnerungen des alten Kontos',
      (tester) async {
    final log = <String>[];
    final repository = _ScriptedAuthRepository(_a);
    addTearDown(repository.dispose);
    await _pumpGate(tester, repository, _RecordingNotifications(log));
    expect(log, ['schedule']);

    repository.emit(null);
    await tester.pumpAndSettle();

    expect(log, ['schedule', 'cancel'],
        reason: 'Sonst feuern A\'s Streak-Erinnerungen weiter, obwohl die '
            'Session abgelaufen oder widerrufen ist.');
    expect(find.byKey(const ValueKey('screen-auth')), findsOneWidget);
  });

  testWidgets(
      'direkter Wechsel A -> B: erst A verwerfen, dann plant B', (tester) async {
    final log = <String>[];
    final repository = _ScriptedAuthRepository(_a);
    addTearDown(repository.dispose);
    await _pumpGate(tester, repository, _RecordingNotifications(log));
    log.clear();

    repository.emit(_b);
    await tester.pumpAndSettle();

    expect(find.text('home user-b'), findsOneWidget);
    expect(log, ['cancel', 'schedule'],
        reason: 'Der Cancel muss vor B\'s Planung in der Warteschlange '
            'stehen, sonst loescht er B\'s Erinnerungen oder A\'s bleiben.');
  });

  testWidgets('Token-Refresh desselben Kontos verwirft nichts',
      (tester) async {
    final log = <String>[];
    final repository = _ScriptedAuthRepository(_a);
    addTearDown(repository.dispose);
    await _pumpGate(tester, repository, _RecordingNotifications(log));
    log.clear();

    repository.emit(_a);
    await tester.pumpAndSettle();

    expect(log, isEmpty);
  });

  testWidgets('Kaltstart ohne Session verwirft Altlasten', (tester) async {
    final log = <String>[];
    final repository = _ScriptedAuthRepository(null);
    addTearDown(repository.dispose);

    await _pumpGate(tester, repository, _RecordingNotifications(log));

    expect(log, ['cancel'],
        reason: 'Die Session endete, waehrend die App nicht lief.');
  });

  testWidgets('Kaltstart mit Session verwirft nichts', (tester) async {
    final log = <String>[];
    final repository = _ScriptedAuthRepository(_a);
    addTearDown(repository.dispose);

    await _pumpGate(tester, repository, _RecordingNotifications(log));

    expect(log, ['schedule']);
  });

  testWidgets(
      'ein werfender Benachrichtigungsdienst haelt den Wechsel nicht auf '
      'und wird gemeldet', (tester) async {
    final reports = <String?>[];
    CrashReporter.debugSentrySink = (error, stack, context) =>
        reports.add(context);
    addTearDown(() => CrashReporter.debugSentrySink = null);
    final log = <String>[];
    final repository = _ScriptedAuthRepository(_a);
    addTearDown(repository.dispose);
    await _pumpGate(
        tester, repository, _RecordingNotifications(log, cancelThrows: true));

    repository.emit(null);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('screen-auth')), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(reports, contains('auth-gate-notification-cancel'));
  });

  // Spec A5: a session end closes rest alerts in the service; only the gate
  // knows when the next account's home takes over, so it reopens them, and
  // always after the cancel of the ended session.
  group('Rest-Alerts (Sitzungsfenster)', () {
    testWidgets('Kaltstart mit Session oeffnet fuer dieses Konto',
        (tester) async {
      final log = <String>[];
      final repository = _ScriptedAuthRepository(_a);
      addTearDown(repository.dispose);

      await _pumpGate(tester, repository, _ScopedNotifications(log));

      expect(log, ['open user-a', 'schedule']);
    });

    testWidgets('Session-Verlust oeffnet nichts, erst der naechste Login',
        (tester) async {
      final log = <String>[];
      final repository = _ScriptedAuthRepository(_a);
      addTearDown(repository.dispose);
      await _pumpGate(tester, repository, _ScopedNotifications(log));
      log.clear();

      repository.emit(null);
      await tester.pumpAndSettle();
      expect(log, ['cancel'],
          reason: 'Ohne Besitzer bleiben Rest-Alerts zu.');

      repository.emit(_b);
      await tester.pumpAndSettle();
      expect(log, ['cancel', 'open user-b', 'schedule']);
    });

    testWidgets('direkter Wechsel A -> B: erst der Cancel, dann oeffnet B',
        (tester) async {
      final log = <String>[];
      final repository = _ScriptedAuthRepository(_a);
      addTearDown(repository.dispose);
      await _pumpGate(tester, repository, _ScopedNotifications(log));
      log.clear();

      repository.emit(_b);
      await tester.pumpAndSettle();

      expect(log, ['cancel', 'open user-b', 'schedule']);
    });

    testWidgets('Kaltstart ohne Session: zu, bis sich jemand anmeldet',
        (tester) async {
      final log = <String>[];
      final repository = _ScriptedAuthRepository(null);
      addTearDown(repository.dispose);
      await _pumpGate(tester, repository, _ScopedNotifications(log));
      expect(log, ['cancel']);

      repository.emit(_a);
      await tester.pumpAndSettle();

      expect(log, ['cancel', 'open user-a', 'schedule']);
    });

    testWidgets('neue Session desselben Kontos oeffnet wieder, ein Refresh '
        'nicht', (tester) async {
      final log = <String>[];
      final repository = _ScriptedAuthRepository(_a);
      addTearDown(repository.dispose);
      await _pumpGate(tester, repository, _ScopedNotifications(log));
      log.clear();

      repository.emit(_a);
      await tester.pumpAndSettle();
      expect(log, isEmpty);

      repository.emit(const EatovaUser(
          id: 'user-a', email: 'a@example.com', sessionId: 's3'));
      await tester.pumpAndSettle();
      expect(log, ['open user-a'],
          reason: 'Nach einem gescheiterten Sign-Out (Cleanup schloss schon) '
              'bekommt die neue Session ihre Rest-Alerts zurueck.');
    });

    testWidgets('Repository-Tausch mit anderem Konto: erst Cancel, dann B',
        (tester) async {
      final log = <String>[];
      final notifications = _ScopedNotifications(log);
      final first = _ScriptedAuthRepository(_a);
      final second = _ScriptedAuthRepository(_b);
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      await _pumpGate(tester, first, notifications);
      log.clear();

      await _pumpGate(tester, second, notifications);

      expect(log.take(2), ['cancel', 'open user-b']);
      expect(find.text('home user-b'), findsOneWidget);
    });
  });

  group('Hintergrund-Sync (Aufraeumen nach dem Sign-Out)', () {
    testWidgets('Session-Ende storniert den OS-Job, ein Refresh nicht',
        (tester) async {
      final scheduler = _RecordingScheduler();
      final repository = _ScriptedAuthRepository(_a);
      addTearDown(repository.dispose);
      await _pumpGate(tester, repository, _RecordingNotifications([]),
          scheduler: scheduler);
      scheduler.log.clear();

      repository.emit(_a);
      await tester.pumpAndSettle();
      expect(scheduler.log, isEmpty);

      repository.emit(null);
      await tester.pumpAndSettle();
      expect(scheduler.log, ['cancel'],
          reason: 'Sonst weckt das OS die App nach dem Sign-Out fuer nichts.');
    });

    testWidgets('A -> B: erst stornieren, dann fordert B neu an',
        (tester) async {
      final scheduler = _RecordingScheduler();
      final repository = _ScriptedAuthRepository(_a);
      addTearDown(repository.dispose);
      await _pumpGate(tester, repository, _RecordingNotifications([]),
          scheduler: scheduler);
      scheduler.log.clear();

      repository.emit(_b);
      await tester.pumpAndSettle();

      expect(scheduler.log, ['cancel', 'request'],
          reason: 'Der naechste Login muss den Job wieder bekommen.');
    });

    testWidgets('Kaltstart ohne Session storniert', (tester) async {
      final scheduler = _RecordingScheduler();
      final repository = _ScriptedAuthRepository(null);
      addTearDown(repository.dispose);

      await _pumpGate(tester, repository, _RecordingNotifications([]),
          scheduler: scheduler);

      expect(scheduler.log, ['cancel']);
    });

    testWidgets('ein werfendes Stornieren wird gemeldet und blockiert nichts',
        (tester) async {
      final reports = <String?>[];
      CrashReporter.debugSentrySink = (error, stack, context) =>
          reports.add(context);
      addTearDown(() => CrashReporter.debugSentrySink = null);
      final log = <String>[];
      final repository = _ScriptedAuthRepository(_a);
      addTearDown(repository.dispose);
      await _pumpGate(tester, repository,
          _RecordingNotifications(log, cancelThrows: true),
          scheduler: _RecordingScheduler(cancelThrows: true));

      repository.emit(null);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('screen-auth')), findsOneWidget);
      expect(reports, containsAll(<String>[
        'auth-gate-notification-cancel',
        'auth-gate-background-sync-cancel',
      ]),
          reason: 'Ein werfender Benachrichtigungsdienst darf das '
              'Stornieren des Hintergrund-Jobs nicht ueberspringen.');
    });
  });

  testWidgetsRobust(
      'EatovaApp reicht Benachrichtigungen und Hintergrund-Sync an das Gate',
      (tester) async {
    final log = <String>[];
    final scheduler = _RecordingScheduler();
    final repository = InMemoryAuthRepository();
    addTearDown(repository.dispose);

    await tester.pumpWidget(EatovaApp(
      authRepository: repository,
      notificationService: _RecordingNotifications(log),
      backgroundSyncScheduler: scheduler,
    ));
    await tester.pump();

    expect(find.byKey(const ValueKey('screen-auth')), findsOneWidget);
    expect(log, ['cancel'],
        reason: 'Ohne Durchreichen bleibt das Gate ohne Dienst und storniert '
            'in Produktion nichts.');
    expect(scheduler.log, ['cancel']);
  });
}
