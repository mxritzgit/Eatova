import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Calls the native window safeguard: `true` = secure (Android FLAG_SECURE /
/// iOS snapshot cover), `false` = released.
typedef SecureScreenInvoker = Future<void> Function(bool secure);

/// Tells the native snapshot cover which page tone to paint.
typedef SecureScreenCoverColorInvoker = Future<void> Function(Color color);

/// Blocks screenshots and the app-switcher preview on sensitive screens
/// (security audit 2026-08-09): OTP code, password field and health data.
///
/// Ref-counted — only the 0↔1 transition calls native, so leaving a nested
/// guard does not clear the flag while the outer screen is still visible. The
/// native channel is unregistered on desktop/web/test, where this is a no-op.
class SecureScreen {
  SecureScreen({
    SecureScreenInvoker? invoker,
    SecureScreenCoverColorInvoker? coverColorInvoker,
  })  : _invoke = invoker ?? _platformInvoke,
        _setCoverColor = coverColorInvoker ?? _platformSetCoverColor;

  /// Process-wide counter — all guards share this instance.
  static final SecureScreen instance = SecureScreen();

  static const MethodChannel _channel = MethodChannel('eatova/secure_screen');

  final SecureScreenInvoker _invoke;
  final SecureScreenCoverColorInvoker _setCoverColor;
  int _active = 0;

  @visibleForTesting
  int get activeCount => _active;

  static Future<void> _platformInvoke(bool secure) async {
    try {
      await _channel.invokeMethod<void>(secure ? 'enable' : 'disable');
    } on MissingPluginException {
      // Desktop/web/test: no native counterpart, so no-op.
    } on PlatformException {
      // A window flag must never crash the UI flow.
    }
  }

  static Future<void> _platformSetCoverColor(Color color) async {
    try {
      await _channel.invokeMethod<void>('setCoverColor', {
        'color': color.toARGB32(),
      });
    } on MissingPluginException {
      // Android draws no cover (FLAG_SECURE blanks the preview);
      // desktop/web/test have no channel.
    } on PlatformException {
      // A cover tone must never crash the UI flow.
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

  /// The page tone of the theme on screen for the iOS snapshot cover. The
  /// in-app theme can differ from the system one, so iOS cannot derive it.
  /// Independent of the hold count.
  Future<void> setCoverColor(Color color) => _setCoverColor(color);
}

/// Wraps a sensitive screen: holds the native secure flag while the screen is
/// in the tree and releases it on unmount.
class SecureScreenGuard extends StatefulWidget {
  const SecureScreenGuard({super.key, required this.child, this.secureScreen});

  final Widget child;

  /// Test seam; production uses [SecureScreen.instance].
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

/// Reports the page tone of the theme on screen to the native snapshot cover:
/// once on mount and again whenever [color] changes. Sits once below the
/// MaterialApp theme, which resolves the in-app and the system choice.
class SecureScreenCoverColor extends StatefulWidget {
  const SecureScreenCoverColor({
    super.key,
    required this.color,
    required this.child,
    this.secureScreen,
  });

  final Color color;
  final Widget child;

  /// Test seam; production uses [SecureScreen.instance].
  final SecureScreen? secureScreen;

  @override
  State<SecureScreenCoverColor> createState() => _SecureScreenCoverColorState();
}

class _SecureScreenCoverColorState extends State<SecureScreenCoverColor> {
  SecureScreen get _secure => widget.secureScreen ?? SecureScreen.instance;

  @override
  void initState() {
    super.initState();
    _secure.setCoverColor(widget.color);
  }

  @override
  void didUpdateWidget(SecureScreenCoverColor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.color != widget.color) _secure.setCoverColor(widget.color);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
