import 'dart:async';

import 'package:flutter/widgets.dart';

import 'glass_blob.dart';
import 'glass_layer.dart';

/// A distortion blob in an enclosing [GlassLayer]'s surface, shaped to this
/// widget's laid-out footprint.
///
/// The blob is injected into the layer behind [layerKey] (see
/// [GlassLayerState.replaceBlob]): nothing is drawn over the panel — the
/// panel's own glass is pushed out by [distortion] logical pixels around
/// this widget, fading over [distortionRange], and takes on [tint] at the
/// same weight.
///
/// Purely declarative and unanimated: whatever the parameters are at build
/// time is what the layer shows, so animation is composed from the outside —
/// rebuild from an [AnimatedBuilder] with different values each tick.
/// [GlassPressSwell] does exactly that for the common press-feedback case.
///
/// At `distortion == 0` no blob is injected at all, rather than a blob of
/// zero strength: a zero-distortion [GlassBlob] would be a *rendered* blob
/// (it merges into the surface), never what a swell at rest means. Zero
/// distortion is exactly zero influence, so animating through it is
/// continuous.
///
/// Geometry is captured when the widget syncs (on update, and once after
/// its first layout): a swell held up while its position changes underneath
/// it — mid-scroll, say — trails until the next rebuild.
class GlassSwell extends StatefulWidget {
  const GlassSwell({
    super.key,
    required this.layerKey,
    required this.child,
    required this.tint,
    this.distortion = 0,
    this.distortionRange = 26,
    this.insets = EdgeInsets.zero,
    this.cornerRadius = double.infinity,
    this.cornerContinuity = 0,
  });

  /// The [GlassLayer] whose surface swells; its key, as passed to
  /// [GlassLayer.key]. This widget must sit inside that layer's child.
  final GlobalKey<GlassLayerState> layerKey;

  final Widget child;

  /// Blob tint, blended into the displaced surface at the push's own
  /// weight. A swell that should push without coloring carries the panel's
  /// tint — not a transparent one, which would locally fade the panel's
  /// (see [GlassBlob.tint] semantics on distortion blobs).
  final Color tint;

  /// How far the layer's surfaces are pushed outward, in logical pixels;
  /// `0` (the default) removes the blob entirely. See [GlassBlob.distortion].
  final double distortion;

  /// How far past this widget's outline the push reaches before fading to
  /// nothing. See [GlassBlob.distortionRange].
  final double distortionRange;

  /// Taken back off the widget's footprint so the swell follows the part
  /// that reads as a button rather than the whole tap target — a tap target
  /// usually reaches further than what the eye calls the button.
  final EdgeInsets insets;

  /// Corner rounding of the swell shape; the default fully rounds it into a
  /// stadium/circle. See [GlassBlob.cornerRadius].
  final double cornerRadius;

  /// See [GlassBlob.cornerContinuity].
  final double cornerContinuity;

  @override
  State<GlassSwell> createState() => _GlassSwellState();
}

class _GlassSwellState extends State<GlassSwell> {
  /// The blob currently in the layer's list, which
  /// [GlassLayerState.replaceBlob] matches by identity, so it's the exact
  /// instance last handed over.
  GlassBlob? _blob;

  @override
  void initState() {
    super.initState();
    // The first sync needs the footprint, which doesn't exist until after
    // the first layout.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _sync();
    });
  }

  @override
  void didUpdateWidget(GlassSwell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.layerKey != widget.layerKey) {
      final oldLayer = oldWidget.layerKey.currentState;
      if (oldLayer != null && oldLayer.mounted && _blob != null) {
        oldLayer.replaceBlob(_blob, null);
        _blob = null;
      }
    }
    // Legal mid-build: replaceBlob is repaint-level, not a setState.
    _sync();
  }

  @override
  void dispose() {
    final layer = widget.layerKey.currentState;
    final blob = _blob;
    if (layer != null && blob != null) {
      // Deferred: mid-teardown the layer itself may be on its way out, and
      // the empty-layer case of replaceBlob needs a rebuild. The stale blob
      // lasts at most one frame of a widget that has just left anyway.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (layer.mounted) layer.replaceBlob(blob, null);
      });
    }
    super.dispose();
  }

  void _sync() {
    final layer = widget.layerKey.currentState;
    if (layer == null || !layer.mounted) return;
    final next = _blobFor(layer);
    if (next == null && _blob == null) return;
    layer.replaceBlob(_blob, next);
    _blob = next;
  }

  GlassBlob? _blobFor(GlassLayerState layer) {
    if (widget.distortion == 0) return null;
    final self = context.findRenderObject() as RenderBox?;
    final layerBox = layer.context.findRenderObject() as RenderBox?;
    if (self == null ||
        layerBox == null ||
        !self.hasSize ||
        !layerBox.hasSize) {
      return null;
    }
    final rect = widget.insets.deflateRect(
        self.localToGlobal(Offset.zero, ancestor: layerBox) & self.size);
    if (rect.isEmpty) return null;
    return GlassBlob(
      center: rect.center,
      radii: Size(rect.width / 2, rect.height / 2),
      cornerRadius: widget.cornerRadius,
      cornerContinuity: widget.cornerContinuity,
      distortion: widget.distortion,
      distortionRange: widget.distortionRange,
      tint: widget.tint,
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Press feedback for a widget sitting on a [GlassLayer]: the panel's glass
/// swells up around [child] on pointer down and sinks back on release, the
/// way a finger under a sheet of something soft would do it. The glass
/// equivalent of an ink well.
///
/// Wraps [child] instead of handling the tap itself: [child] is the real
/// button and keeps its own gesture handling; pointer events are only
/// observed on the way past. All the glass work is a [GlassSwell] driven by
/// an internal press animation — for different timing or coupling to your
/// own animation, compose [GlassSwell] directly.
class GlassPressSwell extends StatefulWidget {
  const GlassPressSwell({
    super.key,
    required this.layerKey,
    required this.child,
    required this.tint,
    this.pressedTint,
    this.insets = EdgeInsets.zero,
    this.depth = 5,
    this.range = 26,
    this.minimumHold = const Duration(milliseconds: 90),
    this.riseDuration = const Duration(milliseconds: 120),
    this.fallDuration = const Duration(milliseconds: 100),
    this.curve = Curves.easeOutCubic,
    this.cornerRadius = double.infinity,
    this.cornerContinuity = 0,
  });

  /// See [GlassSwell.layerKey].
  final GlobalKey<GlassLayerState> layerKey;

  final Widget child;

  /// Swell tint at rest (the moment the press begins); usually the panel's
  /// own glass tint — see [GlassSwell.tint].
  final Color tint;

  /// Swell tint at the height of the press; the swell fades between the
  /// two with the press. Defaults to [tint] at half its alpha, softening
  /// the pressed row against the panel.
  final Color? pressedTint;

  /// See [GlassSwell.insets].
  final EdgeInsets insets;

  /// How far out the surface is pushed at the height of the press, in
  /// logical pixels, and how far past the button's outline that push
  /// reaches before it has faded to nothing. The range is what softens the
  /// bulge into the rest of the panel — too short and the pressed row looks
  /// like a step cut into the edge.
  final double depth;
  final double range;

  /// The swell stays up at least this long after a press begins, no matter
  /// how brief the tap — a tap that came and went in 40ms should still read
  /// as a press, so the down swing is delayed to make up the difference.
  final Duration minimumHold;

  final Duration riseDuration;
  final Duration fallDuration;
  final Curve curve;

  /// See [GlassSwell.cornerRadius] / [GlassSwell.cornerContinuity].
  final double cornerRadius;
  final double cornerContinuity;

  @override
  State<GlassPressSwell> createState() => _GlassPressSwellState();
}

class _GlassPressSwellState extends State<GlassPressSwell>
    with SingleTickerProviderStateMixin {
  late final AnimationController _press = AnimationController(
    duration: widget.riseDuration,
    reverseDuration: widget.fallDuration,
    vsync: this,
  );
  Timer? _fall;
  DateTime _pressedAt = DateTime.now();

  @override
  void didUpdateWidget(GlassPressSwell oldWidget) {
    super.didUpdateWidget(oldWidget);
    _press
      ..duration = widget.riseDuration
      ..reverseDuration = widget.fallDuration;
  }

  @override
  void dispose() {
    _fall?.cancel();
    _press.dispose();
    super.dispose();
  }

  void _handlePointerDown(PointerDownEvent event) {
    _fall?.cancel();
    _pressedAt = DateTime.now();
    // from: 0 rather than plain forward(), which would try to resume from
    // wherever a previous press left off — every press is its own swell.
    _press.forward(from: 0);
  }

  void _handleRelease() {
    final wait = widget.minimumHold - DateTime.now().difference(_pressedAt);
    _fall?.cancel();
    if (wait > Duration.zero) {
      _fall = Timer(wait, () {
        if (mounted) _press.reverse();
      });
    } else {
      _press.reverse();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: _handlePointerDown,
      onPointerUp: (_) => _handleRelease(),
      onPointerCancel: (_) => _handleRelease(),
      child: AnimatedBuilder(
        animation: _press,
        builder: (context, child) {
          final p = widget.curve.transform(_press.value);
          final pressed = widget.pressedTint ??
              widget.tint.withValues(alpha: widget.tint.a / 2);
          return GlassSwell(
            layerKey: widget.layerKey,
            tint: Color.lerp(widget.tint, pressed, p)!,
            distortion: widget.depth * p,
            distortionRange: widget.range,
            insets: widget.insets,
            cornerRadius: widget.cornerRadius,
            cornerContinuity: widget.cornerContinuity,
            child: child!,
          );
        },
        child: widget.child,
      ),
    );
  }
}
