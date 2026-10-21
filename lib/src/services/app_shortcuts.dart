import 'dart:async';

import 'package:clock/clock.dart';
import 'package:quick_actions/quick_actions.dart';

import '../l10n/l10n.dart';
import 'app_entry.dart';
import 'crash_reporter.dart';

/// One app-icon shortcut: where it leads and its title in the app language.
typedef AppShortcut = ({AppEntry entry, String title});

/// The app-icon shortcuts (long press on the icon; review 2026-10-22), in
/// launcher order: capture a meal three ways, or log a weight.
List<AppShortcut> appShortcutsFor(AppLocalizations l10n) => <AppShortcut>[
  (entry: AppEntry.photo, title: l10n.shortcutPhoto),
  (entry: AppEntry.barcode, title: l10n.shortcutBarcode),
  (entry: AppEntry.describe, title: l10n.shortcutDescribe),
  (entry: AppEntry.weighIn, title: l10n.shortcutWeighIn),
];

/// The app-icon shortcuts as a seam, so the shell and the auth gate run
/// without the platform plugin in tests.
///
/// The shell shows them once its account is signed in and onboarded; the
/// auth gate clears them at every session end, so a signed-out app offers
/// none.
abstract class AppShortcuts {
  /// Shortcuts picked while someone listens, the launching one included.
  Stream<AppEntry> get picks;

  /// A pick that arrived while nobody listened, at most once.
  AppEntry? takePendingPick();

  /// Puts [shortcuts] on the app icon, replacing the ones there.
  Future<void> show(List<AppShortcut> shortcuts);

  /// Removes every shortcut.
  Future<void> clear();
}

/// For tests, previews and platforms without shortcuts.
class NoopAppShortcuts implements AppShortcuts {
  const NoopAppShortcuts();

  @override
  Stream<AppEntry> get picks => const Stream<AppEntry>.empty();

  @override
  AppEntry? takePendingPick() => null;

  @override
  Future<void> show(List<AppShortcut> shortcuts) async {}

  @override
  Future<void> clear() async {}
}

/// The `quick_actions` plugin (flutter.dev). It is initialized on first use,
/// once per process: Android reads the launching shortcut from the launch
/// intent at that moment. No icons: the plugin wants native image resources,
/// and the launcher shows the app icon without them.
///
/// Every plugin call is fenced and reported, never thrown at the caller;
/// calls run in invocation order, so a session end's clear lands before the
/// next account's shortcuts.
class PlatformAppShortcuts implements AppShortcuts {
  PlatformAppShortcuts({QuickActions plugin = const QuickActions()})
    : _plugin = plugin;

  final QuickActions _plugin;
  final StreamController<AppEntry> _picks =
      StreamController<AppEntry>.broadcast();
  AppEntry? _pending;
  ({AppEntry entry, DateTime at})? _lastPick;
  Future<void>? _started;
  Future<void> _queue = Future<void>.value();

  /// Android can report the launching shortcut twice: once from its launch
  /// intent and once from the handler message buffered before Dart listened.
  /// The same pick inside this window is one pick.
  static const Duration echoWindow = Duration(seconds: 2);

  Future<void> _start() => _started ??= _initialize();

  Future<void> _initialize() async {
    try {
      await _plugin.initialize(_onAction);
    } catch (e, st) {
      await CrashReporter.capture(e, st, context: 'app-shortcuts-init');
    }
  }

  void _onAction(String type) {
    final entry = AppEntry.tryParse(type);
    if (entry == null) return;
    final now = clock.now();
    final last = _lastPick;
    if (last != null &&
        last.entry == entry &&
        now.difference(last.at) < echoWindow) {
      return;
    }
    _lastPick = (entry: entry, at: now);
    if (_picks.hasListener) {
      _picks.add(entry);
    } else {
      _pending = entry;
    }
  }

  @override
  Stream<AppEntry> get picks {
    unawaited(_start());
    return _picks.stream;
  }

  @override
  AppEntry? takePendingPick() {
    unawaited(_start());
    final pending = _pending;
    _pending = null;
    return pending;
  }

  @override
  Future<void> show(List<AppShortcut> shortcuts) => _enqueue(
    () => _plugin.setShortcutItems(<ShortcutItem>[
      for (final shortcut in shortcuts)
        ShortcutItem(
          type: shortcut.entry.id,
          localizedTitle: shortcut.title,
        ),
    ]),
    'app-shortcuts-show',
  );

  @override
  Future<void> clear() =>
      _enqueue(_plugin.clearShortcutItems, 'app-shortcuts-clear');

  Future<void> _enqueue(Future<void> Function() action, String context) {
    final result = _queue.then((_) async {
      await _start();
      try {
        await action();
      } catch (e, st) {
        await CrashReporter.capture(e, st, context: context);
      }
    });
    _queue = result;
    return result;
  }
}
