import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';

/// Keep Cupertino's interactive back transition. Where a PopScope blocks it,
/// a leading-edge pull still reaches the route's existing exit policy.
class EatovaCupertinoPageTransitionsBuilder
    extends CupertinoPageTransitionsBuilder {
  const EatovaCupertinoPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => _GuardedEdgeBack(
    route: route,
    child: super.buildTransitions(
      route,
      context,
      animation,
      secondaryAnimation,
      child,
    ),
  );
}

class _GuardedEdgeBack extends StatefulWidget {
  const _GuardedEdgeBack({required this.route, required this.child});

  final PageRoute<dynamic> route;
  final Widget child;

  @override
  State<_GuardedEdgeBack> createState() => _GuardedEdgeBackState();
}

class _GuardedEdgeBackState extends State<_GuardedEdgeBack>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pull = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
  );
  double _distance = 0;
  bool _finishing = false;
  bool _keyboardAtStart = false;
  FocusNode? _focusAtStart;

  bool get _enabled =>
      !_finishing &&
      widget.route.isCurrent &&
      widget.route.animation?.status == AnimationStatus.completed &&
      widget.route.secondaryAnimation?.status == AnimationStatus.dismissed &&
      !widget.route.navigator!.userGestureInProgress &&
      !widget.route.popGestureEnabled;

  double get _direction =>
      Directionality.of(context) == TextDirection.ltr ? 1 : -1;

  void _start(DragStartDetails details) {
    _pull.stop();
    _distance = 0;
    _keyboardAtStart = MediaQuery.viewInsetsOf(context).bottom > 0;
    _focusAtStart = FocusManager.instance.primaryFocus;
  }

  void _update(DragUpdateDetails details) {
    _distance = math.max(
      0,
      _distance + (details.primaryDelta ?? 0) * _direction,
    );
    _pull.value = (_distance / MediaQuery.sizeOf(context).width).clamp(0, 1);
  }

  Future<void> _finish({bool exit = false}) async {
    if (_finishing) return;
    _finishing = true;
    if (MediaQuery.disableAnimationsOf(context)) {
      _pull.value = 0;
    } else {
      try {
        await _pull.animateBack(0, curve: Curves.easeOut).orCancel;
      } on TickerCanceled {
        return;
      }
    }
    if (!mounted) return;
    _finishing = false;
    if (!exit || !widget.route.isCurrent) return;
    if (_keyboardAtStart) {
      if (identical(FocusManager.instance.primaryFocus, _focusAtStart)) {
        _focusAtStart?.unfocus();
      }
      return;
    }
    // maybePop preserves dirty-form, workout-checkpoint and onboarding guards.
    await widget.route.navigator?.maybePop();
  }

  @override
  void dispose() {
    _pull.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    return Stack(
      fit: StackFit.expand,
      children: [
        AnimatedBuilder(
          animation: _pull,
          child: widget.child,
          builder: (context, child) => Transform.translate(
            offset: Offset(
              reducedMotion ? 0 : _pull.value * 24 * _direction,
              0,
            ),
            child: child,
          ),
        ),
        PositionedDirectional(
          start: 0,
          top: 0,
          bottom: 0,
          width:
              24 +
              (_direction > 0
                  ? MediaQuery.paddingOf(context).left
                  : MediaQuery.paddingOf(context).right),
          child: RawGestureDetector(
            behavior: HitTestBehavior.translucent,
            excludeFromSemantics: true,
            gestures: <Type, GestureRecognizerFactory>{
              _GuardedBackRecognizer:
                  GestureRecognizerFactoryWithHandlers<_GuardedBackRecognizer>(
                    () => _GuardedBackRecognizer(),
                    (recognizer) {
                      recognizer.enabled = () => _enabled;
                      recognizer.onStart = (details) {
                        recognizer.pointerCanceled = false;
                        _start(details);
                      };
                      recognizer.onUpdate = _update;
                      recognizer.onCancel = () => unawaited(_finish());
                      recognizer.onEnd = (details) {
                        final velocity =
                            (details.primaryVelocity ?? 0) * _direction;
                        final commit = velocity.abs() >= 700
                            ? velocity > 0 && _distance > 0
                            : _distance >= 64;
                        unawaited(
                          _finish(exit: !recognizer.pointerCanceled && commit),
                        );
                      };
                    },
                  ),
            },
          ),
        ),
      ],
    );
  }
}

class _GuardedBackRecognizer extends HorizontalDragGestureRecognizer {
  late bool Function() enabled;
  bool pointerCanceled = false;

  @override
  void handleEvent(PointerEvent event) {
    // An accepted drag reports pointer cancellation through onEnd in Flutter.
    if (event is PointerCancelEvent) pointerCanceled = true;
    super.handleEvent(event);
  }

  @override
  bool isPointerAllowed(PointerEvent event) =>
      enabled() && super.isPointerAllowed(event);
}
