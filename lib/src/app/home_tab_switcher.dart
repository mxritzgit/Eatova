import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../theme/app_tokens.dart';
import '../widgets/common/motion.dart';

/// The shell's tab stack: an [IndexedStack] with a "fade through" switch.
///
/// Keeps the IndexedStack contract (D6): every child stays mounted, is laid
/// out, and only the selected one is hit-tested, in the semantics tree and
/// "onstage" for finders. On a switch the outgoing tab fades out within
/// [outgoingFade] while the incoming one fades in and drifts [drift] px in
/// from the side of its tab-bar position, settling after [duration].
///
/// The fade is a [AppTokens.bg] scrim drawn over each moving tab, not an
/// opacity layer. The tabs sit on that solid background, so the result is the
/// same, but no saveLayer isolates the kcal card's BackdropFilter from what it
/// blurs, and no raster cache has to hold a subtree it cannot cache. Each tab
/// is its own [RepaintBoundary], so a frame only moves layers and redraws the
/// scrim; the tab content is not re-recorded.
class HomeTabSwitcher extends StatefulWidget {
  const HomeTabSwitcher({
    super.key,
    required this.index,
    required this.children,
  });

  /// Full switch, until the incoming tab has settled.
  static const Duration duration = Duration(milliseconds: 260);

  /// The outgoing tab is gone after this part of [duration].
  static const Duration outgoingFade = Duration(milliseconds: 90);

  /// The incoming tab starts to appear after this part of [duration].
  static const Duration incomingDelay = Duration(milliseconds: 40);

  /// Horizontal travel of the incoming tab.
  static const double drift = 10;

  final int index;

  /// One widget per tab; unmounted tabs pass a placeholder.
  final List<Widget> children;

  @override
  State<HomeTabSwitcher> createState() => HomeTabSwitcherState();
}

/// Public for tests: [visibilityOf] and [driftOf] expose the paint state.
class HomeTabSwitcherState extends State<HomeTabSwitcher>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: HomeTabSwitcher.duration,
    value: 1,
  )..addStatusListener(_onStatus);

  late int _current = widget.index;
  int? _outgoing;

  // Start values of the running switch, so an interruption continues from
  // what is on screen instead of jumping.
  double _inStart = 0;
  double _inDriftStart = 0;
  double _outStart = 1;
  double _outDrift = 0;

  static final Curve _outCurve = Interval(
    0,
    _fraction(HomeTabSwitcher.outgoingFade),
    curve: Curves.easeOut,
  );
  static final Curve _inCurve = Interval(
    _fraction(HomeTabSwitcher.incomingDelay),
    1,
    curve: Curves.easeOutCubic,
  );
  static const Curve _driftCurve = Curves.easeOutCubic;

  static double _fraction(Duration part) =>
      part.inMicroseconds / HomeTabSwitcher.duration.inMicroseconds;

  /// How much of tab [index] is visible (0 = not painted, 1 = fully).
  @visibleForTesting
  double visibilityOf(int index) {
    final t = _controller.value;
    if (index == _current) {
      return _inStart + (1 - _inStart) * _inCurve.transform(t);
    }
    if (index == _outgoing) return _outStart * (1 - _outCurve.transform(t));
    return 0;
  }

  /// Horizontal paint offset of tab [index].
  @visibleForTesting
  double driftOf(int index) {
    if (index == _current) {
      return _inDriftStart * (1 - _driftCurve.transform(_controller.value));
    }
    if (index == _outgoing) return _outDrift;
    return 0;
  }

  @override
  void didUpdateWidget(HomeTabSwitcher oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.index != _current) _switchTo(widget.index);
  }

  void _switchTo(int next) {
    final duration = motionDuration(context, HomeTabSwitcher.duration);
    if (duration == Duration.zero) {
      _controller.value = 1;
      _outgoing = null;
      _current = next;
      return;
    }
    // Interrupted switch: the tab on its way in becomes the outgoing one from
    // where it is; a tab called back resumes from its remaining visibility.
    // A third tab still fading out is dropped (it is nearly gone by then).
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final side = (next > _current) != rtl ? 1.0 : -1.0;
    final nextVisible = visibilityOf(next);
    final nextDrift = driftOf(next);
    _outStart = visibilityOf(_current);
    _outDrift = driftOf(_current);
    _inStart = nextVisible;
    _inDriftStart = nextVisible > 0
        ? nextDrift
        : side * HomeTabSwitcher.drift;
    _outgoing = _current;
    _current = next;
    _controller
      ..duration = duration
      ..forward(from: 0);
  }

  void _onStatus(AnimationStatus status) {
    if (status.isCompleted && _outgoing != null && mounted) {
      setState(() => _outgoing = null);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final children = widget.children;
    return _FadeThroughStack(
      current: _current,
      outgoing: _outgoing,
      state: this,
      animation: _controller,
      scrim: context.t.bg,
      children: <Widget>[
        for (var i = 0; i < children.length; i++)
          // Visibility.of for Ink decorations, like IndexedStack's scope:
          // a hidden tab must not paint onto the shared Material.
          Visibility.maintain(
            visible: i == _current || i == _outgoing,
            child: RepaintBoundary(child: children[i]),
          ),
      ],
    );
  }
}

class _FadeThroughStack extends Stack {
  const _FadeThroughStack({
    required this.current,
    required this.outgoing,
    required this.state,
    required this.animation,
    required this.scrim,
    super.children,
  }) : super(fit: StackFit.expand, clipBehavior: Clip.none);

  final int current;
  final int? outgoing;
  final HomeTabSwitcherState state;
  final Animation<double> animation;
  final Color scrim;

  @override
  RenderStack createRenderObject(BuildContext context) => _RenderFadeThrough(
    current: current,
    outgoing: outgoing,
    state: state,
    animation: animation,
    scrim: scrim,
    textDirection: Directionality.maybeOf(context),
  );

  @override
  void updateRenderObject(BuildContext context, RenderStack renderObject) {
    super.updateRenderObject(context, renderObject);
    (renderObject as _RenderFadeThrough)
      ..current = current
      ..outgoing = outgoing
      ..state = state
      ..animation = animation
      ..scrim = scrim;
  }

  @override
  MultiChildRenderObjectElement createElement() => _FadeThroughElement(this);
}

/// Only the selected tab is onstage for finders, like in an IndexedStack.
class _FadeThroughElement extends MultiChildRenderObjectElement {
  _FadeThroughElement(_FadeThroughStack super.widget);

  @override
  void debugVisitOnstageChildren(ElementVisitor visitor) {
    final current = (widget as _FadeThroughStack).current;
    if (current < children.length) visitor(children.elementAt(current));
  }
}

class _RenderFadeThrough extends RenderStack {
  _RenderFadeThrough({
    required int current,
    required int? outgoing,
    required this.state,
    required Animation<double> animation,
    required Color scrim,
    super.textDirection,
  }) : _current = current,
       _outgoing = outgoing,
       _animation = animation,
       _scrim = scrim,
       super(fit: StackFit.expand, clipBehavior: Clip.none);

  HomeTabSwitcherState state;

  int get current => _current;
  int _current;
  set current(int value) {
    if (value == _current) return;
    _current = value;
    markNeedsPaint();
    markNeedsSemanticsUpdate();
  }

  int? _outgoing;
  set outgoing(int? value) {
    if (value == _outgoing) return;
    _outgoing = value;
    markNeedsPaint();
  }

  Animation<double> _animation;
  set animation(Animation<double> value) {
    if (value == _animation) return;
    if (attached) _animation.removeListener(markNeedsPaint);
    _animation = value;
    if (attached) _animation.addListener(markNeedsPaint);
    markNeedsPaint();
  }

  Color _scrim;
  set scrim(Color value) {
    if (value == _scrim) return;
    _scrim = value;
    markNeedsPaint();
  }

  // Ticks only re-record this layer: the moving tabs are boundaries.
  @override
  bool get isRepaintBoundary => true;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _animation.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _animation.removeListener(markNeedsPaint);
    super.detach();
  }

  RenderBox? _childAt(int? index) {
    if (index == null) return null;
    var child = firstChild;
    for (var i = 0; i < index && child != null; i++) {
      child = childAfter(child);
    }
    return child;
  }

  int _indexOf(RenderBox child) {
    var i = 0;
    for (var c = firstChild; c != null; c = childAfter(c), i++) {
      if (identical(c, child)) return i;
    }
    return -1;
  }

  Offset _offsetOf(RenderBox child, int index) =>
      (child.parentData! as StackParentData).offset +
      Offset(state.driftOf(index), 0);

  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) {
    final child = _childAt(_current);
    if (child != null) visitor(child);
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    // Only the incoming tab takes input, from the first frame on.
    final child = _childAt(_current);
    if (child == null) return false;
    return result.addWithPaintOffset(
      offset: _offsetOf(child, _current),
      position: position,
      hitTest: (result, transformed) =>
          child.hitTest(result, position: transformed),
    );
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    final offset = _offsetOf(child, _indexOf(child));
    transform.translateByDouble(offset.dx, offset.dy, 0, 1);
  }

  @override
  void paintStack(PaintingContext context, Offset offset) {
    // Outgoing below, incoming on top, whatever their order in the bar.
    final outgoing = _outgoing;
    if (outgoing != null && outgoing != _current) {
      _paintTab(context, offset, outgoing);
    }
    _paintTab(context, offset, _current);
  }

  void _paintTab(PaintingContext context, Offset offset, int index) {
    final child = _childAt(index);
    if (child == null) return;
    final visibility = state.visibilityOf(index);
    if (visibility <= 0) return;
    final drift = state.driftOf(index);
    context.paintChild(child, offset + _offsetOf(child, index));
    if (visibility >= 1) return;
    // Scrim over the tab AND its drift, so no unfaded strip shows beside it.
    final rect = offset & size;
    context.canvas.drawRect(
      Rect.fromLTRB(
        rect.left - drift.abs(),
        rect.top,
        rect.right + drift.abs(),
        rect.bottom,
      ),
      Paint()..color = _scrim.withValues(alpha: _scrim.a * (1 - visibility)),
    );
  }

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties
      ..add(IntProperty('current', _current))
      ..add(IntProperty('outgoing', _outgoing, defaultValue: null));
  }
}
