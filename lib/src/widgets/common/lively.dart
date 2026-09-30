import 'dart:async';

import 'package:flutter/gestures.dart' show kPressTimeout, kTouchSlop;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'motion.dart';

// ---------------------------------------------------------------------------
// LIVELY — the small motion vocabulary of the tabs (2026-10-01).
//
//  * [LivelyEntrance]      one block fades in and rises once.
//  * [LivelyStaggerScope]  + [LivelyStaggerItem]: a first view's sections
//                          enter one after another, once per mount.
//  * [LivelyInsert]        a row added to a live list grows in.
//  * [PressScale]          a control sinks a little while pressed.
//  * [CountingText]        a number counts to its new value.
//
// Shared rules: durations and the curve come from `motion.dart` and pass
// through [motionDuration]/[reducedMotion], so "reduce motion" shows every end
// state at once. Only opacity and transforms animate (paint work), except
// [LivelyInsert]'s height and [CountingText]'s glyphs. Every widget keeps the
// same widget structure at rest and in flight, so a finished animation leaves
// the pixels, keys and semantics of the plain child, and nothing repeats, so
// `pumpAndSettle` terminates.
// ---------------------------------------------------------------------------

/// Subtle entrance: soft fade-in plus a slight upward glide.
///
/// The child always stays in the widget tree (only opacity/transform change),
/// so hit-testing, keys and widget tests are untouched. A changing [key]
/// replays the entrance.
///
/// When a [LivelyStaggerScope] mounts inside it, the entrance steps aside
/// after its first frame and the scope's sections carry the motion alone, so
/// a tab never fades twice.
class LivelyEntrance extends StatefulWidget {
  const LivelyEntrance({
    super.key,
    required this.child,
    this.offsetY = 10,
    this.duration = const Duration(milliseconds: 320),
    this.curve = kMotionCurve,
  });

  final Widget child;
  final double offsetY;
  final Duration duration;
  final Curve curve;

  @override
  State<LivelyEntrance> createState() => _LivelyEntranceState();
}

class _LivelyEntranceState extends State<LivelyEntrance>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final CurvedAnimation _curved;

  /// What the transitions read: the curved entrance, or "done" once a nested
  /// stagger took over. Swapping the parent keeps the widget tree unchanged.
  late final ProxyAnimation _anim;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: widget.duration);
    _curved = CurvedAnimation(parent: _controller, curve: widget.curve);
    _anim = ProxyAnimation(_curved);
    _controller.forward();
  }

  void _standDown() {
    if (!mounted) return;
    _controller.stop();
    _anim.parent = kAlwaysCompleteAnimation;
  }

  @override
  void dispose() {
    _curved.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final child = _EntranceHost(standDown: _standDown, child: widget.child);
    // A11y: respect "reduce motion" — show the content statically.
    if (reducedMotion(context)) return child;
    // FadeTransition instead of a raw animated Opacity: the latter forces a
    // saveLayer (offscreen raster of the whole page) every frame. The
    // RepaintBoundary rasters the page once so the entrance only recomposites
    // the finished layer; the glide stays a cheap transform layer.
    return FadeTransition(
      opacity: _anim,
      child: AnimatedBuilder(
        animation: _anim,
        builder: (context, child) {
          return Transform.translate(
            offset: Offset(0, (1 - _anim.value) * widget.offsetY),
            child: child,
          );
        },
        child: RepaintBoundary(child: child),
      ),
    );
  }
}

/// Lets a nested [LivelyStaggerScope] ask the enclosing [LivelyEntrance] to
/// step aside. Never rebuilds dependents: the callback is looked up, not
/// depended on.
class _EntranceHost extends InheritedWidget {
  const _EntranceHost({required this.standDown, required super.child});

  final VoidCallback standDown;

  @override
  bool updateShouldNotify(_EntranceHost oldWidget) => false;
}

/// Staggered first-view entrance: every [LivelyStaggerItem] below fades in
/// and rises [LivelyStaggerItem.offsetY] px, [kMotionStagger] after the
/// previous index.
///
/// Plays ONCE per mount. In the home shell a visited tab stays mounted
/// (IndexedStack), so the entrance runs the first time a tab is shown in a
/// session and never again on return. Items that mount later (lazy list rows,
/// a filter change, another day) find the scope finished and appear as they
/// are. Under a hidden tab's `TickerMode(false)` the controller does not run.
class LivelyStaggerScope extends StatefulWidget {
  const LivelyStaggerScope({super.key, required this.child});

  final Widget child;

  /// Highest stagger index; later items share its slot, so a long page
  /// still finishes in [total].
  static const int maxIndex = 4;

  /// Duration of the whole entrance: the last slot's start plus one entrance
  /// (30 × 4 + 240 = 360 ms).
  static Duration get total => kMotionStagger * maxIndex + kMotionEnter;

  @override
  State<LivelyStaggerScope> createState() => _LivelyStaggerScopeState();
}

class _LivelyStaggerScopeState extends State<LivelyStaggerScope>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: LivelyStaggerScope.total,
  );
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (reducedMotion(context)) {
      _controller.value = 1;
      return;
    }
    _controller.forward();
    final host = context.getInheritedWidgetOfExactType<_EntranceHost>();
    if (host != null) {
      // Not during build: the entrance is an ancestor that already built.
      WidgetsBinding.instance.addPostFrameCallback((_) => host.standDown());
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _StaggerScope(animation: _controller, child: widget.child);
}

class _StaggerScope extends InheritedWidget {
  const _StaggerScope({required this.animation, required super.child});

  final Animation<double> animation;

  @override
  bool updateShouldNotify(_StaggerScope oldWidget) =>
      animation != oldWidget.animation;
}

/// Wraps the sections of a column in [LivelyStaggerItem]s, indexed top to
/// bottom; spacers ([SizedBox]) stay as they are and take no index.
///
/// Each wrapper is keyed after its section (the section's own key, else its
/// type and occurrence), so a section appearing or disappearing above keeps
/// the others' state: without keys the column would pair the identical
/// wrappers by position and remount whatever sits below the change.
List<Widget> livelyStagger(List<Widget> children) {
  final seen = <Type, int>{};
  var index = 0;
  return <Widget>[
    for (final child in children)
      if (child is SizedBox && child.child == null)
        child
      else
        LivelyStaggerItem(
          key: child.key == null
              ? ValueKey<Object>((
                  child.runtimeType,
                  seen.update(
                    child.runtimeType,
                    (n) => n + 1,
                    ifAbsent: () => 0,
                  ),
                ))
              : ValueKey<Key>(child.key!),
          index: index++,
          child: child,
        ),
  ];
}

/// One section of a [LivelyStaggerScope]'s first view.
///
/// Without a scope, under "reduce motion" or after the scope finished, it is
/// its plain [child]: opacity 1 and a zero translation paint no extra layer.
class LivelyStaggerItem extends StatefulWidget {
  const LivelyStaggerItem({
    super.key,
    required this.index,
    required this.child,
    // 6 px, not more: on a first visit the shell's fade-through drifts the
    // whole tab as well, and the two must read as one soft arrival.
    this.offsetY = 6,
  });

  /// Position in the stagger, 0 first; clamped to
  /// [LivelyStaggerScope.maxIndex].
  final int index;
  final double offsetY;
  final Widget child;

  @override
  State<LivelyStaggerItem> createState() => _LivelyStaggerItemState();
}

class _LivelyStaggerItemState extends State<LivelyStaggerItem> {
  Animation<double>? _parent;
  int? _index;
  CurvedAnimation? _curved;
  Animation<double> _anim = kAlwaysCompleteAnimation;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  @override
  void didUpdateWidget(LivelyStaggerItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index != widget.index) _resolve();
  }

  void _resolve() {
    final scope = context
        .dependOnInheritedWidgetOfExactType<_StaggerScope>()
        ?.animation;
    final parent = scope == null || reducedMotion(context) ? null : scope;
    final index = widget.index.clamp(0, LivelyStaggerScope.maxIndex);
    if (parent == _parent && index == _index) return;
    _parent = parent;
    _index = index;
    _curved?.dispose();
    _curved = null;
    if (parent == null) {
      _anim = kAlwaysCompleteAnimation;
      return;
    }
    final total = LivelyStaggerScope.total.inMicroseconds;
    final offset = (kMotionStagger * index).inMicroseconds;
    final start = offset / total;
    final end = (offset + kMotionEnter.inMicroseconds) / total;
    _anim = _curved = CurvedAnimation(
      parent: parent,
      curve: Interval(start, end, curve: kMotionCurve),
    );
  }

  @override
  void dispose() {
    _curved?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final anim = _anim;
    return FadeTransition(
      opacity: anim,
      child: AnimatedBuilder(
        animation: anim,
        builder: (context, child) => Transform.translate(
          offset: Offset(0, (1 - anim.value) * widget.offsetY),
          child: child,
        ),
        child: widget.child,
      ),
    );
  }
}

/// A row that grows in (height) and fades in when [animate] is true at its
/// first build — for an entry added to a list that is already on screen.
///
/// The caller decides what is new (e.g. an id that was not there on the
/// previous build); rows present at first display pass `false` and render as
/// they are. [animate] is read once: later rebuilds do not replay.
class LivelyInsert extends StatefulWidget {
  const LivelyInsert({super.key, required this.animate, required this.child});

  final bool animate;
  final Widget child;

  @override
  State<LivelyInsert> createState() => _LivelyInsertState();
}

class _LivelyInsertState extends State<LivelyInsert>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    value: widget.animate ? 0 : 1,
  );
  late final CurvedAnimation _size = CurvedAnimation(
    parent: _controller,
    curve: kMotionCurve,
  );
  // The content fades in once most of its room is there.
  late final CurvedAnimation _fade = CurvedAnimation(
    parent: _controller,
    curve: const Interval(0.35, 1, curve: kMotionCurve),
  );
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (_controller.value < 1) {
      _controller.duration = motionDuration(context, kMotionEnter);
      _controller.forward();
    }
  }

  @override
  void dispose() {
    _size.dispose();
    _fade.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _size,
    builder: (context, child) =>
        _HeightFactor(factor: _size.value, child: child),
    child: FadeTransition(opacity: _fade, child: widget.child),
  );
}

/// Reports [factor] of its child's height and clips to it, laying the child
/// out with the incoming constraints unchanged.
///
/// Not `SizeTransition`: its `Align` loosens the constraints, so a row that
/// fills the width in a stretched column would shrink to its content even at
/// rest. At factor 1 this paints the child directly, without a clip.
class _HeightFactor extends SingleChildRenderObjectWidget {
  const _HeightFactor({required this.factor, super.child});

  final double factor;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderHeightFactor(factor);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderHeightFactor renderObject,
  ) => renderObject.factor = factor;
}

class _RenderHeightFactor extends RenderProxyBox {
  _RenderHeightFactor(this._factor);

  double _factor;
  set factor(double value) {
    final clamped = value.clamp(0.0, 1.0);
    if (clamped == _factor) return;
    _factor = clamped;
    markNeedsLayout();
  }

  bool get _clips => _factor < 1;

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    child.layout(constraints, parentUsesSize: true);
    size = constraints.constrain(
      Size(child.size.width, child.size.height * _factor),
    );
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final childSize = child?.getDryLayout(constraints) ?? Size.zero;
    return constraints.constrain(
      Size(childSize.width, childSize.height * _factor),
    );
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (child == null) return;
    if (!_clips) {
      layer = null;
      context.paintChild(child!, offset);
      return;
    }
    layer = context.pushClipRect(
      needsCompositing,
      offset,
      Offset.zero & size,
      (context, offset) => context.paintChild(child!, offset),
      oldLayer: layer as ClipRectLayer?,
    );
  }

  @override
  Rect? describeApproximatePaintClip(RenderObject child) =>
      _clips ? Offset.zero & size : null;
}

/// Scale of a pressed [PressScale]: 3 % smaller — buttons, pills, chips.
const double kPressScale = 0.97;

/// The dip of a full-width card: 1.5 %, so a 350 px card moves ~2.6 px per
/// side like a 44 px button does ~0.7 px, instead of visibly collapsing.
const double kPressScaleCard = 0.985;

/// Press feedback: [child] sinks to [scale] while a finger rests on it and
/// eases back on release. A quick tap still shows the full dip.
///
/// Only listens to raw pointers, so it never joins the gesture arena: taps,
/// long presses and ink ripples of the child behave exactly as before, and a
/// scroll that starts on the child does not press it (like InkWell, the dip
/// waits [kPressTimeout] and a move past [kTouchSlop] cancels it). The
/// transform does not touch hit-testing or layout. At rest the scale is 1,
/// which paints no extra layer.
class PressScale extends StatefulWidget {
  const PressScale({
    super.key,
    required this.child,
    this.enabled = true,
    this.scale = kPressScale,
  });

  final Widget child;

  /// Off for a disabled control: no dip without an action.
  final bool enabled;
  final double scale;

  @override
  State<PressScale> createState() => _PressScaleState();
}

class _PressScaleState extends State<PressScale>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: kMotionPressIn,
    reverseDuration: kMotionPressOut,
  );
  late final CurvedAnimation _curve = CurvedAnimation(
    parent: _controller,
    curve: kMotionCurve,
    // flipped: the release eases out in time as well.
    reverseCurve: kMotionCurve.flipped,
  );

  Timer? _delay;
  int? _pointer;
  Offset _origin = Offset.zero;

  /// "Reduce motion", as of the last build.
  bool _reduced = false;

  bool get _active => widget.enabled && !_reduced;

  void _down(PointerDownEvent event) {
    if (_pointer != null || !_active) return;
    _pointer = event.pointer;
    _origin = event.position;
    _delay?.cancel();
    _delay = Timer(kPressTimeout, () {
      _pressIn();
    });
  }

  void _move(PointerMoveEvent event) {
    if (event.pointer != _pointer) return;
    if ((event.position - _origin).distance > kTouchSlop) _cancel();
  }

  void _up(PointerUpEvent event) {
    if (event.pointer != _pointer) return;
    _pointer = null;
    final waiting = _delay?.isActive ?? false;
    _delay?.cancel();
    if (waiting) {
      // A tap faster than the delay: dip fully, then ease back.
      _pressIn().whenCompleteOrCancel(() {
        if (mounted && _pointer == null) _release();
      });
    } else {
      _release();
    }
  }

  void _cancel([PointerCancelEvent? event]) {
    if (event != null && event.pointer != _pointer) return;
    _pointer = null;
    _delay?.cancel();
    _release();
  }

  TickerFuture _pressIn() {
    if (!mounted) return TickerFuture.complete();
    _controller
      ..duration = motionDuration(context, kMotionPressIn)
      ..reverseDuration = motionDuration(context, kMotionPressOut);
    return _controller.forward();
  }

  void _release() {
    if (_controller.value > 0) _controller.reverse();
  }

  @override
  void didUpdateWidget(PressScale oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled && oldWidget.enabled) _cancel();
  }

  @override
  void dispose() {
    _delay?.cancel();
    _curve.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _reduced = reducedMotion(context);
    return Listener(
      onPointerDown: _down,
      onPointerMove: _move,
      onPointerUp: _up,
      onPointerCancel: _cancel,
      child: AnimatedBuilder(
        animation: _curve,
        builder: (context, child) => Transform.scale(
          scale: 1 - (1 - widget.scale) * _curve.value,
          transformHitTests: false,
          child: child,
        ),
        child: widget.child,
      ),
    );
  }
}

/// A number that counts to its new [value] instead of jumping: from [from]
/// on first display, from the number on screen when [value] changes.
///
/// [format] turns the running value into the text (thousands separators,
/// units, "58% eaten"); it receives doubles, so round there. The text carries
/// [textKey] and, at rest, is exactly `Text(format(value), style: style)`, so
/// finders, `Text.data` and pixels are those of a plain text.
///
/// In flight the box keeps the RESTING text's size (an invisible copy lays
/// it out), so nothing around the number reflows while it counts — a wider
/// or narrower running figure would otherwise wrap a neighbour or nudge a
/// card's height every frame. The running figure paints over that box,
/// aligned like the text, with tabular figures for the digits that still
/// change. Screen readers hear the final text.
class CountingText extends StatelessWidget {
  const CountingText({
    super.key,
    required this.value,
    required this.format,
    this.from = 0,
    this.textKey,
    this.style,
    this.textAlign,
    this.maxLines,
    this.softWrap,
    this.textScaler,
    this.semanticsLabel,
  });

  final double value;
  final String Function(double value) format;

  /// Where the first display starts. A "left" figure starts at the full
  /// budget, so it counts down while the eaten share fills up.
  final double from;
  final Key? textKey;
  final TextStyle? style;
  final TextAlign? textAlign;
  final int? maxLines;
  final bool? softWrap;
  final TextScaler? textScaler;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final target = value.isFinite ? value : 0.0;
    final end = format(target);
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: from.isFinite ? from : 0, end: target),
      duration: motionDuration(context, kMotionValue),
      curve: kMotionCurve,
      builder: (context, shown, _) {
        final now = format(shown);
        if (now == end) {
          return Text(
            end,
            key: textKey,
            style: style,
            textAlign: textAlign,
            maxLines: maxLines,
            softWrap: softWrap,
            textScaler: textScaler,
            semanticsLabel: semanticsLabel,
          );
        }
        final align = switch (textAlign) {
          TextAlign.center => AlignmentDirectional.center,
          TextAlign.end => AlignmentDirectional.centerEnd,
          TextAlign.right =>
            Directionality.of(context) == TextDirection.ltr
                ? AlignmentDirectional.centerEnd
                : AlignmentDirectional.centerStart,
          _ => AlignmentDirectional.centerStart,
        };
        return Stack(
          clipBehavior: Clip.none,
          children: <Widget>[
            // Sizes the box like the resting text; not painted, not read.
            Visibility(
              visible: false,
              maintainState: true,
              maintainAnimation: true,
              maintainSize: true,
              child: Text(
                end,
                style: style,
                textAlign: textAlign,
                maxLines: maxLines,
                softWrap: softWrap,
                textScaler: textScaler,
              ),
            ),
            Positioned.fill(
              child: OverflowBox(
                maxWidth: double.infinity,
                alignment: align,
                child: Text.rich(
                  TextSpan(children: countingSpans(now, end, style)),
                  key: textKey,
                  style: style,
                  textAlign: textAlign,
                  maxLines: 1,
                  softWrap: false,
                  textScaler: textScaler,
                  semanticsLabel: semanticsLabel ?? end,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Splits [now] into spans: digits that still change get tabular figures,
/// everything settled keeps [style] as is.
///
/// A digit is settled when it and everything before it already match [end]
/// (same length). The count is monotonic, so a settled prefix never changes
/// again, and the last frame equals the resting text glyph for glyph.
@visibleForTesting
List<TextSpan> countingSpans(String now, String end, TextStyle? style) {
  final tabular = (style ?? const TextStyle()).copyWith(
    fontFeatures: <FontFeature>[
      ...?style?.fontFeatures,
      const FontFeature.tabularFigures(),
    ],
  );
  final spans = <TextSpan>[];
  final buffer = StringBuffer();
  bool? bufferTabular;
  var settled = now.length == end.length;
  for (var i = 0; i < now.length; i++) {
    final char = now[i];
    if (settled && char != end[i]) settled = false;
    final code = char.codeUnitAt(0);
    final digit = code >= 0x30 && code <= 0x39;
    final useTabular = digit && !settled;
    if (bufferTabular != null && bufferTabular != useTabular) {
      spans.add(
        TextSpan(
          text: buffer.toString(),
          style: bufferTabular ? tabular : null,
        ),
      );
      buffer.clear();
    }
    bufferTabular = useTabular;
    buffer.write(char);
  }
  if (buffer.isNotEmpty) {
    spans.add(
      TextSpan(text: buffer.toString(), style: bufferTabular! ? tabular : null),
    );
  }
  return spans;
}
