import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'glass_blob.dart';
import 'glass_options.dart';
import 'packing.dart';
import 'shine_motion.dart';

/// Renders a set of liquid-glass [blobs] that merge into a single blobby
/// surface, with [child] painted on top of the glass and clipped to the
/// merged blob silhouette.
///
/// Layering, bottom to top:
///  1. Whatever is painted behind this widget (the backdrop). In
///     [GlassMode.glass] the blobs refract, blur, tint and shine over it.
///     In [GlassMode.flat] the blobs are plain (possibly transparent) tint
///     fills instead.
///  2. [child], masked to the blob silhouette (its coverage, including the
///     smooth merge bridges), so it reads as content sitting on the glass.
///  3. In [GlassMode.glass], the rim shine, drawn topmost and unmasked so
///     the highlight fully covers the glass edge's AA fringe.
///
/// [GlassMode.glass] picks the glass path when the backend supports it and
/// falls back to flat otherwise, rather than throwing.
///
/// The rendered blobs are [blobs] concatenated with the result of
/// [blobBuilder] (if any); the builder runs at paint time against the
/// layer's laid-out size, [CustomPainter]-style, so blobs can be placed
/// relative to the panel's actual dimensions. If [blobBuilder] is null and
/// [blobs] is empty, [child] is rendered unmasked and no overlay is drawn.
/// The glass overlay ignores pointer events; hit testing goes to [child].
class GlassLayer extends StatefulWidget {
  const GlassLayer({
    super.key,
    required this.child,
    required this.blobs,
    this.blobBuilder,
    this.options = const GlassOptions(),
  }) : assert(blobs.length <= maxBlobs,
            'GlassLayer supports at most $maxBlobs blobs');

  final Widget child;
  final List<GlassBlob> blobs;

  /// Builds additional blobs from the layer's laid-out size. Like
  /// [CustomPainter.paint] or [CustomClipper.getClip], it is called at paint
  /// time, after layout, so the size is the one [child] actually resolved to
  /// (the layer sizes itself to [child]) — not a constraint bound. Its result
  /// is appended to [blobs]; the combined list must stay within [maxBlobs]
  /// (checked with an assert when packing).
  ///
  /// The builder re-runs when the layer rebuilds or its size changes; between
  /// rebuilds its result is cached per size, and it may run for several
  /// passes per frame — keep it cheap and pure. To animate its output,
  /// rebuild the [GlassLayer] (e.g. from an [AnimatedBuilder]).
  ///
  /// When a [blobBuilder] is present the layer always paints its mask, so a
  /// builder yielding no blobs (with [blobs] also empty) leaves an empty
  /// silhouette that masks [child] out entirely — consistent with every blob
  /// having animated away — unlike the builder-less empty-[blobs] case, which
  /// short-circuits to rendering [child] unmasked.
  final List<GlassBlob> Function(Size size)? blobBuilder;

  final GlassOptions options;

  /// Maximum number of blobs per layer.
  static const int maxBlobCount = maxBlobs;

  /// Loads the shader programs ahead of time. Optional; a [GlassLayer] built
  /// before the programs are ready renders [child] unmasked and no glass for
  /// those frames.
  static Future<void> precache() => _GlassPrograms.ensureLoaded();

  @override
  State<GlassLayer> createState() => _GlassLayerState();
}

class _GlassPrograms {
  static ui.FragmentProgram? glass;
  static ui.FragmentProgram? flat;
  static Future<void>? _loading;

  static bool get loaded => glass != null && flat != null;

  static Future<void> ensureLoaded() {
    return _loading ??= () async {
      glass = await _load('shaders/glass.frag');
      flat = await _load('shaders/flat.frag');
    }();
  }

  // Inside a consuming app the asset lives under the package prefix; in this
  // package's own tests and example it resolves unprefixed.
  static Future<ui.FragmentProgram> _load(String path) async {
    try {
      return await ui.FragmentProgram.fromAsset(
          'packages/just_liquid_glass/$path');
    } catch (_) {
      return ui.FragmentProgram.fromAsset(path);
    }
  }
}

// Uniform float indices in flat.frag.
const int _flatBlobCount = 0;
const int _flatBlendRadius = 1;
const int _flatMode = 2; // 0 = tint fill, 1 = coverage mask, 2 = shine
const int _flatDpr = 3;
const int _flatShineIntensity = 4;
const int _flatShineDirection = 5;
const int _flatBevelThickness = 6;
const int _flatBlobsStart = 7;

/// Resolves the effective blob list — the static [GlassLayer.blobs] plus the
/// [GlassLayer.blobBuilder] output — into the packed uniform floats and the
/// padded shading bounds.
///
/// One instance is created per [GlassLayer] build and shared by every pass
/// (backdrop/fill, mask, shine). Each pass calls [resolveFor] from its paint
/// with its own laid-out size; all passes fill the layer, so the sizes agree
/// and the work runs once, cached until the size changes. Without a builder
/// the list is size-independent and resolved eagerly.
class _BlobResolver {
  _BlobResolver(this.blobs, this.builder, this.options) {
    if (builder == null) _resolve(blobs);
  }

  final List<GlassBlob> blobs;
  final List<GlassBlob> Function(Size size)? builder;
  final GlassOptions options;

  Size? _resolvedSize;

  /// Number of blobs in the resolved list.
  int count = 0;

  /// Packed shader uniforms for the resolved list; see [packBlobs].
  Float32List packed = Float32List(0);

  /// Bounding rect of the merged field ([Rect.zero] when [count] is 0),
  /// padded so smooth-min bulges, the AA band, and (for the glass pass)
  /// refraction displacement and the engine blur's read reach (~3 sigma =
  /// 1.5 * blurRadius) all stay inside it. Shading is restricted to this
  /// region so GPU cost scales with blob area rather than screen area.
  Rect bounds = Rect.zero;

  /// Re-resolves against [size] if it changed; call from paint with the
  /// pass's laid-out size.
  void resolveFor(Size size) {
    if (builder == null || _resolvedSize == size) return;
    _resolvedSize = size;
    final built = builder!(size);
    _resolve(blobs.isEmpty
        ? built
        : built.isEmpty
            ? blobs
            : [...blobs, ...built]);
  }

  void _resolve(List<GlassBlob> all) {
    count = all.length;
    packed = packBlobs(all);
    if (all.isEmpty) {
      bounds = Rect.zero;
      return;
    }
    var b = blobBounds(all.first);
    for (final blob in all.skip(1)) {
      b = b.expandToInclude(blobBounds(blob));
    }
    final pad = options.blendRadius +
        options.refractionIntensity +
        1.5 * options.blurRadius +
        8;
    bounds = b.inflate(pad);
  }

  /// Whether swapping [old] for [current] can change painted output. Builder
  /// closures can't be compared, so any builder forces a repaint — the same
  /// convention [CustomPainter.shouldRepaint] implementations use for
  /// callbacks.
  static bool repaintNeeded(_BlobResolver old, _BlobResolver current) {
    if (identical(old, current)) return false;
    if (old.builder != null || current.builder != null) return true;
    return !listEquals(old.blobs, current.blobs);
  }
}

class _GlassLayerState extends State<GlassLayer> {
  ui.FragmentShader? _glassShader;
  ui.FragmentShader? _fillShader;
  ui.FragmentShader? _maskShader;
  ui.FragmentShader? _shineShader;
  bool _motionRetained = false;

  @override
  void initState() {
    super.initState();
    if (!_GlassPrograms.loaded) {
      _GlassPrograms.ensureLoaded().then((_) {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncMotion();
  }

  @override
  void didUpdateWidget(GlassLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncMotion();
  }

  @override
  void dispose() {
    if (_motionRetained) {
      _motionRetained = false;
      ShineMotion.instance.release();
    }
    _glassShader?.dispose();
    _fillShader?.dispose();
    _maskShader?.dispose();
    _shineShader?.dispose();
    super.dispose();
  }

  /// Retains the shared accelerometer while this layer can actually show a
  /// moving highlight: motion shine on, a visible shine, the glass path
  /// resolved, and no platform request for reduced motion (parity with
  /// Liquid Glass calming down under iOS Reduce Motion).
  void _syncMotion() {
    final options = widget.options;
    final wants = options.motionShine &&
        options.shineIntensity > 0 &&
        _resolveMode() == GlassMode.glass &&
        !(MediaQuery.maybeDisableAnimationsOf(context) ?? false);
    if (wants == _motionRetained) return;
    _motionRetained = wants;
    if (wants) {
      ShineMotion.instance.retain();
    } else {
      ShineMotion.instance.release();
    }
  }

  GlassMode _resolveMode() {
    switch (widget.options.mode) {
      case GlassMode.flat:
        return GlassMode.flat;
      case GlassMode.glass:
        return ui.ImageFilter.isShaderFilterSupported
            ? GlassMode.glass
            : GlassMode.flat;
    }
  }

  double _dprOf(BuildContext context) =>
      MediaQuery.maybeDevicePixelRatioOf(context) ??
      View.of(context).devicePixelRatio;

  void _setFlatUniforms(ui.FragmentShader shader, _BlobResolver resolver,
      double mode, double dpr) {
    final options = widget.options;
    final packed = resolver.packed;
    shader.setFloat(_flatBlobCount, resolver.count.toDouble());
    shader.setFloat(_flatBlendRadius, options.blendRadius);
    shader.setFloat(_flatMode, mode);
    shader.setFloat(_flatDpr, dpr);
    shader.setFloat(_flatShineIntensity, options.shineIntensity);
    shader.setFloat(_flatShineDirection, options.shineDirection);
    shader.setFloat(_flatBevelThickness, options.bevelThickness);
    for (var i = 0; i < packed.length; i++) {
      shader.setFloat(_flatBlobsStart + i, packed[i]);
    }
  }

  Widget _flatPass(ui.FragmentShader shader, _BlobResolver resolver,
      double mode, double dpr,
      {ValueListenable<double>? shineTilt}) {
    return CustomPaint(
      size: Size.infinite,
      painter: _FlatBlobPainter(
        shader: shader,
        resolver: resolver,
        mode: mode,
        options: widget.options,
        dpr: dpr,
        shineTilt: shineTilt,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_GlassPrograms.loaded ||
        (widget.blobBuilder == null && widget.blobs.isEmpty)) {
      return widget.child;
    }

    final dpr = _dprOf(context);
    final glass = _resolveMode() == GlassMode.glass;
    // Blobs are only needed at paint time, and only then is the layer's true
    // size (the size the child chose in layout) known — so nothing is packed
    // here; every pass resolves through this shared per-build resolver from
    // its paint method instead.
    final resolver =
        _BlobResolver(widget.blobs, widget.blobBuilder, widget.options);

    Widget overlay;
    if (glass) {
      final view = View.of(context);
      overlay = _GlassBackdrop(
        shader: _glassShader ??= _GlassPrograms.glass!.fragmentShader(),
        resolver: resolver,
        options: widget.options,
        dpr: dpr,
        viewSize: view.physicalSize / view.devicePixelRatio,
      );
    } else {
      overlay = _flatPass(_fillShader ??= _GlassPrograms.flat!.fragmentShader(),
          resolver, 0, dpr);
    }

    final maskedChild = ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (maskBounds) {
        // A paint-time hook: maskBounds is the child's laid-out rect.
        final shader = _maskShader ??= _GlassPrograms.flat!.fragmentShader();
        resolver.resolveFor(maskBounds.size);
        _setFlatUniforms(shader, resolver, 1, dpr);
        return shader;
      },
      child: widget.child,
    );

    return Stack(
      fit: StackFit.passthrough,
      // Non-directional alignment: works without a Directionality ancestor
      // (it is irrelevant here, the overlay is Positioned.fill).
      alignment: Alignment.topLeft,
      children: [
        Positioned.fill(child: IgnorePointer(child: overlay)),
        maskedChild,
        // The rim shine draws topmost, OUTSIDE the mask's dstIn save layer:
        // inside it, the mask caps the shine's alpha at the same coverage
        // that draws the tinted glass edge, so the AA fringe can never be
        // fully covered — a jaggy dark hairline capped the shine on
        // dark-tint-over-light scenes. The shine shader cuts its own outer
        // edge half a band outside the silhouette instead, fully covering
        // the glass fringe. Flat mode stays flat (no shine).
        if (glass)
          Positioned.fill(
            child: IgnorePointer(
              child: _flatPass(
                  _shineShader ??= _GlassPrograms.flat!.fragmentShader(),
                  resolver,
                  2,
                  dpr,
                  // Sensor ticks repaint only this pass; the backdrop
                  // (refraction/blur) never sees them.
                  shineTilt:
                      _motionRetained ? ShineMotion.instance.tilt : null),
            ),
          ),
      ],
    );
  }
}

// uOrigin and uClip float indices in glass.frag.
const int _glassOriginX = 7;
const int _glassOriginY = 8;
const int _glassClipStart = 9; // 9..12: LTRB, GlassLayer-local logical px
const int _glassEdgeTintStart = 13; // 13..16: uEdgeTint rgba
const int _glassBlobsStart = 17;

/// A [BackdropFilter] variant that fills the GlassLayer and writes every
/// glass uniform at paint time.
///
/// Everything the shader needs is only final at paint time. The blob list may
/// come from [GlassLayer.blobBuilder], which resolves against the laid-out
/// size. FlutterFragCoord() inside an ImageFilter.shader is anchored to the
/// full render target, while blob centers are GlassLayer-local, so the shader
/// needs the layer's origin within the target (uOrigin) — and since this
/// render object fills the layer, that is simply its own global position,
/// resolved via [RenderBox.localToGlobal] in [paint]. The filter is clipped
/// there too, to the resolver's padded blob bounds, so GPU cost scales with
/// blob area rather than layer area.
class _GlassBackdrop extends SingleChildRenderObjectWidget {
  const _GlassBackdrop({
    required this.shader,
    required this.resolver,
    required this.options,
    required this.dpr,
    required this.viewSize,
  }) : super(child: const SizedBox.expand());

  final ui.FragmentShader shader;
  final _BlobResolver resolver;
  final GlassOptions options;
  final double dpr;

  /// Size of the view (the backdrop render target) in logical pixels, used
  /// to trim the filter clip to the render target at paint time.
  final Size viewSize;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderGlassBackdrop(shader, resolver, options, dpr, viewSize);

  @override
  void updateRenderObject(
      BuildContext context, _RenderGlassBackdrop renderObject) {
    // The shader's uniforms are mutated in place on each paint and the
    // resolver is rebuilt each build, so repaint even when the fields
    // compare identical.
    renderObject
      ..shader = shader
      ..resolver = resolver
      ..options = options
      ..dpr = dpr
      ..viewSize = viewSize
      ..markNeedsPaint();
  }
}

class _RenderGlassBackdrop extends RenderProxyBox {
  _RenderGlassBackdrop(
      this.shader, this.resolver, this.options, this.dpr, this.viewSize);

  ui.FragmentShader shader;
  _BlobResolver resolver;
  GlassOptions options;
  double dpr;
  Size viewSize;

  ClipRectLayer? _clipLayer;

  @override
  bool get alwaysNeedsCompositing => true;

  @override
  void dispose() {
    _clipLayer = null;
    super.dispose();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    // We fill the GlassLayer, so our size is the layer's laid-out size.
    resolver.resolveFor(size);
    if (resolver.count == 0) return;

    // Global logical coordinates match the backdrop render target as long as
    // no ancestor saveLayer re-targets rendering; a GlassLayer inside e.g. an
    // Opacity already samples that layer's (empty) backdrop anyway. Filling
    // the layer also means our global top-left is the GlassLayer's origin
    // and our local coordinates are GlassLayer-local.
    final globalTopLeft = localToGlobal(Offset.zero);

    // Restrict shading to the padded blob region, trimmed to the layer and
    // to the render target (a clip past the target is meaningless to the
    // engine, and skipping paint entirely when nothing is visible is free).
    final ownBounds = Offset.zero & size;
    final visible = resolver.bounds
        .intersect(ownBounds)
        .intersect((Offset.zero - globalTopLeft) & viewSize);
    if (visible.isEmpty) return;

    // Float indices 0 and 1 (uSize) are filled in by the engine. All other
    // uniforms must be written before ui.ImageFilter.shader captures the
    // uniform state below.
    shader.setFloat(2, dpr);
    shader.setFloat(3, resolver.count.toDouble());
    shader.setFloat(4, options.blendRadius);
    shader.setFloat(5, options.bevelThickness);
    shader.setFloat(6, options.refractionIntensity);
    shader.setFloat(_glassOriginX, globalTopLeft.dx);
    shader.setFloat(_glassOriginY, globalTopLeft.dy);
    // uClip: the effective clip in GlassLayer-local (== our local)
    // coordinates. The composed filter's texture only holds valid data
    // inside it — beyond it (the texture can span the whole clip, even where
    // the clip overhangs the render target) lie uninitialized texels — so
    // the shader clamps every backdrop sample into this rect.
    shader.setFloat(_glassClipStart, visible.left);
    shader.setFloat(_glassClipStart + 1, visible.top);
    shader.setFloat(_glassClipStart + 2, visible.right);
    shader.setFloat(_glassClipStart + 3, visible.bottom);
    shader.setFloat(_glassEdgeTintStart, options.edgeTint.r);
    shader.setFloat(_glassEdgeTintStart + 1, options.edgeTint.g);
    shader.setFloat(_glassEdgeTintStart + 2, options.edgeTint.b);
    shader.setFloat(_glassEdgeTintStart + 3, options.edgeTint.a);
    final packed = resolver.packed;
    for (var i = 0; i < packed.length; i++) {
      shader.setFloat(_glassBlobsStart + i, packed[i]);
    }

    // Blur via a composed inner filter: the engine's downsampled gaussian
    // handles arbitrarily wide radii, and the shader receives the blurred
    // backdrop as its input texture. It outputs premultiplied coverage
    // (transparent outside the blobs), so the default srcOver composite of
    // the BackdropFilter keeps the sharp backdrop visible around the glass.
    // Safe on Flutter >= 3.41 (flutter#170820 fixed by flutter#177687).
    // Sigma matches the old in-shader spiral (its gaussian weights used
    // sigma = radius / 2); zero composes no blur and the shader samples the
    // sharp backdrop.
    final blurSigma = options.blurRadius / 2;
    final shaderFilter = ui.ImageFilter.shader(shader);
    final layer = (this.layer as BackdropFilterLayer?) ?? BackdropFilterLayer();
    layer.filter = blurSigma > 0
        ? ui.ImageFilter.compose(
            outer: shaderFilter,
            // Clamp, not the composed-inner default (decal): where the clip
            // region or the render target cuts off the backdrop — a blob near
            // the GlassLayer/screen edge — decal blends toward transparent
            // black and the shader would paint that as a dark border. Clamp
            // replicates the edge pixels instead, matching iOS materials.
            inner: ui.ImageFilter.blur(
                sigmaX: blurSigma,
                sigmaY: blurSigma,
                tileMode: ui.TileMode.clamp),
          )
        : shaderFilter;
    this.layer = layer;

    if (visible == ownBounds) {
      _clipLayer = null;
      context.pushLayer(layer, super.paint, offset);
    } else {
      _clipLayer = context.pushClipRect(
        needsCompositing,
        offset,
        visible,
        (context, offset) => context.pushLayer(layer, super.paint, offset),
        oldLayer: _clipLayer,
      );
    }
  }
}

class _FlatBlobPainter extends CustomPainter {
  _FlatBlobPainter({
    required this.shader,
    required this.resolver,
    required this.mode,
    required this.options,
    required this.dpr,
    this.shineTilt,
  }) : super(repaint: shineTilt);

  final ui.FragmentShader shader;
  final _BlobResolver resolver;
  final double mode;
  final GlassOptions options;
  final double dpr;

  /// Device roll added to the shine direction at paint time; also the
  /// repaint trigger, so sensor updates skip build entirely.
  final ValueListenable<double>? shineTilt;

  @override
  void paint(Canvas canvas, Size size) {
    resolver.resolveFor(size);
    if (resolver.count == 0) return;
    // Shader coordinates are canvas-local either way; drawing only the blob
    // region just skips the fragments that would come out transparent.
    final region = resolver.bounds.intersect(Offset.zero & size);
    if (region.isEmpty) return;
    final packed = resolver.packed;
    shader.setFloat(_flatBlobCount, resolver.count.toDouble());
    shader.setFloat(_flatBlendRadius, options.blendRadius);
    shader.setFloat(_flatMode, mode);
    shader.setFloat(_flatDpr, dpr);
    shader.setFloat(_flatShineIntensity, options.shineIntensity);
    shader.setFloat(_flatShineDirection,
        options.shineDirection + (shineTilt?.value ?? 0));
    shader.setFloat(_flatBevelThickness, options.bevelThickness);
    for (var i = 0; i < packed.length; i++) {
      shader.setFloat(_flatBlobsStart + i, packed[i]);
    }
    canvas.drawRect(region, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(_FlatBlobPainter oldDelegate) {
    return oldDelegate.mode != mode ||
        oldDelegate.options != options ||
        oldDelegate.shineTilt != shineTilt ||
        oldDelegate.dpr != dpr ||
        _BlobResolver.repaintNeeded(oldDelegate.resolver, resolver);
  }
}
