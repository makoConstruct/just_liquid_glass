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
/// If [blobs] is empty, [child] is rendered unmasked and no overlay is drawn.
/// The glass overlay ignores pointer events; hit testing goes to [child].
class GlassLayer extends StatefulWidget {
  const GlassLayer({
    super.key,
    required this.child,
    required this.blobs,
    this.options = const GlassOptions(),
  }) : assert(blobs.length <= maxBlobs,
            'GlassLayer supports at most $maxBlobs blobs');

  final Widget child;
  final List<GlassBlob> blobs;
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

  /// Bounding rect of the merged field, padded so smooth-min bulges, the AA
  /// band, and (for the glass pass) refraction displacement and the engine
  /// blur's read reach (~3 sigma = 1.5 * blurRadius) all stay inside it.
  /// Shading is restricted to this region so GPU cost scales with blob area
  /// rather than screen area.
  Rect _paddedBounds() {
    final options = widget.options;
    var bounds = blobBounds(widget.blobs.first);
    for (final blob in widget.blobs.skip(1)) {
      bounds = bounds.expandToInclude(blobBounds(blob));
    }
    final pad = options.blendRadius +
        options.refractionIntensity +
        1.5 * options.blurRadius +
        8;
    return bounds.inflate(pad);
  }

  Widget _buildGlassOverlay(
      BuildContext context, Float32List packed, double dpr, Rect bounds) {
    final shader = _glassShader ??= _GlassPrograms.glass!.fragmentShader();
    final options = widget.options;

    return LayoutBuilder(builder: (context, constraints) {
      final layer = Offset.zero & constraints.biggest;
      final region = bounds.intersect(layer);
      if (region.isEmpty) return const SizedBox.shrink();

      // Float indices 0 and 1 (uSize) are filled in by the engine. The
      // backdrop texture and FlutterFragCoord stay anchored to the full
      // render target even though the filter is clipped to `region`, so the
      // clip needs no compensation — but FlutterFragCoord is therefore in
      // *global* coordinates while blob centers are GlassLayer-local, so the
      // shader needs the layer's origin (uOrigin). That origin is only final
      // at paint time, so _GlassBackdrop sets it (and creates the filter)
      // in its paint pass rather than here.
      shader.setFloat(2, dpr);
      shader.setFloat(3, widget.blobs.length.toDouble());
      shader.setFloat(4, options.blendRadius);
      shader.setFloat(5, options.bevelThickness);
      shader.setFloat(6, options.refractionIntensity);
      // uClip (floats 9..12) is set at paint time by _GlassBackdrop: the
      // blurred backdrop handed to the shader only has valid content inside
      // the *effective* clip — the region trimmed to the render target —
      // and that trim needs the layer's global position, final only at
      // paint time.
      shader.setFloat(_glassEdgeTintStart, options.edgeTint.r);
      shader.setFloat(_glassEdgeTintStart + 1, options.edgeTint.g);
      shader.setFloat(_glassEdgeTintStart + 2, options.edgeTint.b);
      shader.setFloat(_glassEdgeTintStart + 3, options.edgeTint.a);
      for (var i = 0; i < packed.length; i++) {
        shader.setFloat(_glassBlobsStart + i, packed[i]);
      }

      final view = View.of(context);
      return Padding(
        padding: EdgeInsets.fromLTRB(
          region.left,
          region.top,
          layer.width - region.right,
          layer.height - region.bottom,
        ),
        child: ClipRect(
          child: _GlassBackdrop(
            shader: shader,
            regionOrigin: region.topLeft,
            // Engine-blur sigma matching the old in-shader spiral (its
            // gaussian weights used sigma = radius / 2).
            blurSigma: options.blurRadius / 2,
            viewSize: view.physicalSize / view.devicePixelRatio,
          ),
        ),
      );
    });
  }

  void _setFlatUniforms(
      ui.FragmentShader shader, Float32List packed, double mode, double dpr) {
    final options = widget.options;
    shader.setFloat(_flatBlobCount, widget.blobs.length.toDouble());
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

  Widget _flatPass(ui.FragmentShader shader, Float32List packed, double mode,
      double dpr, Rect bounds,
      {ValueListenable<double>? shineTilt}) {
    return CustomPaint(
      size: Size.infinite,
      painter: _FlatBlobPainter(
        shader: shader,
        packed: packed,
        mode: mode,
        options: widget.options,
        blobCount: widget.blobs.length,
        dpr: dpr,
        bounds: bounds,
        shineTilt: shineTilt,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_GlassPrograms.loaded || widget.blobs.isEmpty) {
      return widget.child;
    }

    final dpr = _dprOf(context);
    final packed = packBlobs(widget.blobs);
    final glass = _resolveMode() == GlassMode.glass;
    final bounds = _paddedBounds();

    Widget overlay;
    if (glass) {
      overlay = _buildGlassOverlay(context, packed, dpr, bounds);
    } else {
      final shader = _fillShader ??= _GlassPrograms.flat!.fragmentShader();
      overlay = _flatPass(shader, packed, 0, dpr, bounds);
    }

    final maskedChild = ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (maskBounds) {
        final shader = _maskShader ??= _GlassPrograms.flat!.fragmentShader();
        _setFlatUniforms(shader, packed, 1, dpr);
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
                  packed,
                  2,
                  dpr,
                  bounds,
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

/// A [BackdropFilter] variant that anchors the glass shader to this widget.
///
/// FlutterFragCoord() inside an ImageFilter.shader is anchored to the full
/// render target, while blob centers are GlassLayer-local, so the shader
/// needs the GlassLayer's origin within the target (uOrigin). That offset is
/// only final at paint time — at build time ancestors may not have positioned
/// us yet — so this render object resolves it via [RenderBox.localToGlobal]
/// in [paint] and creates the [ui.ImageFilter] there, after all uniforms are
/// written.
class _GlassBackdrop extends SingleChildRenderObjectWidget {
  const _GlassBackdrop({
    required this.shader,
    required this.regionOrigin,
    required this.blurSigma,
    required this.viewSize,
  }) : super(child: const SizedBox.expand());

  final ui.FragmentShader shader;

  /// This widget's offset within the GlassLayer (the padded blob region's
  /// top-left), subtracted from our global position to recover the
  /// GlassLayer's own origin.
  final Offset regionOrigin;

  /// Gaussian sigma of the inner engine blur, in logical pixels. Zero
  /// composes no blur and the shader samples the sharp backdrop.
  final double blurSigma;

  /// Size of the view (the backdrop render target) in logical pixels, used
  /// to trim the filter clip to the render target at paint time.
  final Size viewSize;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderGlassBackdrop(shader, regionOrigin, blurSigma, viewSize);

  @override
  void updateRenderObject(
      BuildContext context, _RenderGlassBackdrop renderObject) {
    // The shader's uniforms are mutated in place each build, so repaint even
    // when the fields compare identical.
    renderObject
      ..shader = shader
      ..regionOrigin = regionOrigin
      ..blurSigma = blurSigma
      ..viewSize = viewSize
      ..markNeedsPaint();
  }
}

class _RenderGlassBackdrop extends RenderProxyBox {
  _RenderGlassBackdrop(
      this.shader, this.regionOrigin, this.blurSigma, this.viewSize);

  ui.FragmentShader shader;
  Offset regionOrigin;
  double blurSigma;
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
    // Global logical coordinates match the backdrop render target as long as
    // no ancestor saveLayer re-targets rendering; a GlassLayer inside e.g. an
    // Opacity already samples that layer's (empty) backdrop anyway.
    final globalTopLeft = localToGlobal(Offset.zero);
    final origin = globalTopLeft - regionOrigin;
    shader.setFloat(_glassOriginX, origin.dx);
    shader.setFloat(_glassOriginY, origin.dy);

    final ownBounds = Offset.zero & size;
    final visible =
        ((Offset.zero - globalTopLeft) & viewSize).intersect(ownBounds);
    if (visible.isEmpty) return; // Entirely off the render target.

    // uClip: the effective clip in GlassLayer-local coordinates. The
    // composed filter's texture only holds valid data inside it — beyond it
    // (the texture can span the whole clip, even where the clip overhangs
    // the render target) lie uninitialized texels — so the shader clamps
    // every backdrop sample into this rect. Must be written before
    // ui.ImageFilter.shader captures the uniform state below.
    final clip = visible.shift(regionOrigin);
    shader.setFloat(_glassClipStart, clip.left);
    shader.setFloat(_glassClipStart + 1, clip.top);
    shader.setFloat(_glassClipStart + 2, clip.right);
    shader.setFloat(_glassClipStart + 3, clip.bottom);

    // Blur via a composed inner filter: the engine's downsampled gaussian
    // handles arbitrarily wide radii, and the shader receives the blurred
    // backdrop as its input texture. It outputs premultiplied coverage
    // (transparent outside the blobs), so the default srcOver composite of
    // the BackdropFilter keeps the sharp backdrop visible around the glass.
    // Safe on Flutter >= 3.41 (flutter#170820 fixed by flutter#177687).
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

    // Trim the filter to the render target: a clip past the target is
    // meaningless to the engine, and skipping paint entirely when the layer
    // is fully off-screen is free.
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
    required this.packed,
    required this.mode,
    required this.options,
    required this.blobCount,
    required this.dpr,
    required this.bounds,
    this.shineTilt,
  }) : super(repaint: shineTilt);

  final ui.FragmentShader shader;
  final Float32List packed;
  final double mode;
  final GlassOptions options;
  final int blobCount;
  final double dpr;
  final Rect bounds;

  /// Device roll added to the shine direction at paint time; also the
  /// repaint trigger, so sensor updates skip build entirely.
  final ValueListenable<double>? shineTilt;

  @override
  void paint(Canvas canvas, Size size) {
    // Shader coordinates are canvas-local either way; drawing only the blob
    // region just skips the fragments that would come out transparent.
    final region = bounds.intersect(Offset.zero & size);
    if (region.isEmpty) return;
    shader.setFloat(_flatBlobCount, blobCount.toDouble());
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
    if (oldDelegate.mode != mode ||
        oldDelegate.options != options ||
        oldDelegate.shineTilt != shineTilt ||
        oldDelegate.blobCount != blobCount ||
        oldDelegate.dpr != dpr ||
        oldDelegate.bounds != bounds ||
        oldDelegate.packed.length != packed.length) {
      return true;
    }
    if (identical(oldDelegate.packed, packed)) return false;
    for (var i = 0; i < packed.length; i++) {
      if (oldDelegate.packed[i] != packed[i]) return true;
    }
    return false;
  }
}
