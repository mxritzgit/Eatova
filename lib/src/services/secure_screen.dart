import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Ruft die native Fenster-Absicherung auf: `true` = sicher (Android
/// FLAG_SECURE / iOS Snapshot-Cover), `false` = wieder frei.
typedef SecureScreenInvoker = Future<void> Function(bool secure);

/// Schutz gegen Screenshots und das Vorschaubild im App-Umschalter für
/// sensible Screens (Sicherheits-Audit 2026-08-09): der 8-stellige Code,
/// das Passwort-Feld und die Gesundheitsdaten sollen nicht im
/// Android-Recents-Thumbnail bzw. iOS-App-Switcher-Snapshot auftauchen.
///
/// **Ref-gezählt**: nur der Übergang 0↔1 löst den nativen Aufruf aus. So
/// löscht das Verlassen eines verschachtelten Guards (z. B. AuthCodeScreen
/// über AuthScreen) das Flag nicht, solange der äußere Screen noch sichtbar
/// ist. Der native Kanal ist auf Desktop/Web/Test nicht registriert — dort
/// ist alles ein gefahrloses No-Op.
class SecureScreen {
  SecureScreen({SecureScreenInvoker? invoker})
      : _invoke = invoker ?? _platformInvoke;

  /// Prozessweiter Zähler — alle Guards teilen sich diese Instanz.
  static final SecureScreen instance = SecureScreen();

  static const MethodChannel _channel = MethodChannel('eatova/secure_screen');

  final SecureScreenInvoker _invoke;
  int _active = 0;

  @visibleForTesting
  int get activeCount => _active;

  static Future<void> _platformInvoke(bool secure) async {
    try {
      await _channel.invokeMethod<void>(secure ? 'enable' : 'disable');
    } on MissingPluginException {
      // Desktop/Web/Test: kein natives Gegenstück → No-Op.
    } on PlatformException {
      // Ein Fenster-Flag darf den UI-Fluss nie zum Absturz bringen.
    }
  }

  Future<void> acquire() async {
    _active++;
    if (_active == 1) await _invoke(true);
  }

  Future<void> release() async {
    if (_active == 0) return;
    _active--;
    if (_active == 0) await _invoke(false);
  }
}

/// Umschließt einen sensiblen Screen: hält das native Sicher-Flag, solange
/// der Screen im Baum ist. Beim Unmount (Zurück-Navigation, Logout) gibt er
/// es wieder frei.
class SecureScreenGuard extends StatefulWidget {
  const SecureScreenGuard({super.key, required this.child, this.secureScreen});

  final Widget child;

  /// Test-Naht; Produktion nutzt [SecureScreen.instance].
  final SecureScreen? secureScreen;

  @override
  State<SecureScreenGuard> createState() => _SecureScreenGuardState();
}

class _SecureScreenGuardState extends State<SecureScreenGuard> {
  SecureScreen get _secure => widget.secureScreen ?? SecureScreen.instance;

  @override
  void initState() {
    super.initState();
    _secure.acquire();
  }

  @override
  void dispose() {
    _secure.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
