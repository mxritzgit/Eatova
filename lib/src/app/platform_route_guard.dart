import 'package:flutter/widgets.dart';

/// Swallows every platform route push (Audit 2026-08-14).
///
/// The BROWSABLE intent filter lets any app send `eatova://…`, which Android
/// also replays as a route name. This app has no named routes, so the failed
/// `pushNamed` would let an attacker flood Sentry remotely. `onUnknownRoute`
/// can only redirect a push, not cancel it, so the guard sits above the
/// Navigator: observers are asked in registration order and `true` ends
/// delivery. The real OAuth return runs over `app_links` and is unaffected.
///
/// Wrap the `MaterialApp` in it: the guard registers in [State.initState],
/// before the app below registers its own observer. Used by the app and by
/// the boot error screen.
class PlatformRouteGuard extends StatefulWidget {
  const PlatformRouteGuard({super.key, required this.child});

  final Widget child;

  @override
  State<PlatformRouteGuard> createState() => _PlatformRouteGuardState();
}

class _PlatformRouteGuardState extends State<PlatformRouteGuard>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Future<bool> didPushRouteInformation(RouteInformation routeInformation) =>
      Future<bool>.value(true);

  @override
  Widget build(BuildContext context) => widget.child;
}
