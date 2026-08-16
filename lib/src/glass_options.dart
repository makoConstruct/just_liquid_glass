import 'dart:math' as math;
import 'dart:ui' show Color, Offset;

import 'package:flutter/painting.dart' show EdgeInsets;

/// How a [GlassLayer] renders its blobs.
enum GlassMode {
  /// Full liquid glass: refraction, blur, tint and shine over the backdrop.
  /// Uses Impeller (`ImageFilter.shader`) where available — iOS, Android and
  /// macOS — and falls back to [flat] on backends that lack it (Skia, web).
  glass,

  /// Flat fill: the same merged blobby silhouette, filled with each blob's
  /// tint (which may be translucent or fully transparent). Works on every
  /// backend, including Skia and web.
  flat,
}

/// Rendering options for a [GlassLayer].
class GlassOptions {
  const GlassOptions({
    this.shineIntensity = 0.6,
    this.shineDirection = math.pi / 2,
    this.motionShine = true,
    this.bevelThickness = 17,
    this.refractionIntensity = 22,
    this.childRefractionIntensity = 0,
    this.blurRadius = 17,
    this.blendRadius = 18,
    this.edgeTint = const Color(0x00000000),
    this.shadowRadius = 28,
    this.shadowIntensity = 0.15,
    this.shadowOffset = const Offset(0, 2),
    this.mode = GlassMode.glass,
  });

  /// Strength of the rim highlight (0 disables it).
  final double shineIntensity;

  /// Direction the light comes from, in radians. The default of `pi / 2`
  /// lights the blobs from the top of the screen. With [motionShine] active
  /// this is the direction while the device is held upright.
  final double shineDirection;

  /// Rotates [shineDirection] by the device's roll (from the accelerometer)
  /// so the highlight stays anchored in world space as the device tilts,
  /// like iOS 26's Liquid Glass. Applies in glass mode when the platform has
  /// an accelerometer; elsewhere — and when the platform requests reduced
  /// motion — the shine quietly stays at [shineDirection]. Sensor angles are
  /// relative to the device's natural (portrait) orientation, so in a
  /// rotated app the light anchors to the device, not the world.
  final bool motionShine;

  /// Width of the refractive bevel along the blob rims, in logical pixels.
  final double bevelThickness;

  /// Maximum backdrop displacement at the rim, in logical pixels.
  final double refractionIntensity;

  /// Maximum displacement of the [GlassLayer] child at the rim, in logical
  /// pixels — the child's content bends through the bevel like the backdrop
  /// does, instead of sitting flat on the glass. defaults 0 because it looks bold and intense and chaotic, mainly useful for lerping down from a high value on appearance animation.
  final double childRefractionIntensity;

  /// Backdrop blur radius in logical pixels (glass mode only). Realized as
  /// an engine gaussian with sigma = radius / 2 composed under the glass
  /// shader, so wide radii cost the same as narrow ones.
  final double blurRadius;

  /// Smooth-min merge radius: how far apart blobs start visually fusing,
  /// in logical pixels. Larger values are blobbier.
  final double blendRadius;

  /// Color layered over the blob tints across the bevel band, deepening
  /// toward the silhouette the way real tinted glass darkens edge-on (the
  /// view path through the slab gets longer). This is what keeps the
  /// silhouette legible over a same-colored backdrop — white on white —
  /// where refraction alone disappears; try black at ~15% alpha. Alpha
  /// scales the strength, [bevelThickness] sets the band width, and the
  /// transparent default disables it. Glass mode only ([GlassMode.flat]
  /// relies on its fill tint for contrast instead).
  final Color edgeTint;

  /// How far the drop shadow reaches past the silhouette, in logical pixels
  /// (0 disables the blur, leaving a hard-edged offset silhouette; set
  /// [shadowIntensity] to 0 to disable the shadow itself).
  ///
  /// The shadow is cast by the same merged distance field the glass is,
  /// evaluated beyond the surface instead of inside it, so it follows the
  /// blobby silhouette — merge bridges, distortion pushes and all — with no
  /// second pass, no extra texture and no path to build. It is drawn by the
  /// glass (or flat-fill) pass itself, underneath the child, and is occluded
  /// by the blobs' own coverage, so an offset shadow never shows through the
  /// glass it belongs to.
  ///
  /// This is a blur radius, not an offset distance: alpha falls from
  /// [shadowIntensity] a full radius inside the silhouette (invisible, under
  /// the glass) to half of it exactly at the silhouette, to 0 one radius
  /// out — the profile a gaussian-blurred silhouette has, and the reason a
  /// shadow with no [shadowOffset] still reads as a soft halo rather than a
  /// flat ring.
  final double shadowRadius;

  /// Peak opacity of the drop shadow (0 disables it, and skips all of its
  /// cost). The shadow is black; this is its alpha where it is deepest, half
  /// of which lands at the silhouette edge — so the darkest *visible* pixel
  /// of an unoffset shadow is `shadowIntensity / 2`.
  final double shadowIntensity;

  /// Displacement of the drop shadow from the silhouette, in logical pixels;
  /// positive dy pushes it down the screen.
  ///
  /// A non-zero offset costs a second evaluation of the distance field in the
  /// shadow band (the field has to be sampled at the shifted point), which
  /// [Offset.zero] avoids by reusing the one the glass already computed.
  final Offset shadowOffset;

  /// Which rendering path to use; see [GlassMode].
  final GlassMode mode;

  /// How far the shadow extends past the silhouette on each side, once
  /// [shadowRadius] and [shadowOffset] are both accounted for — the padding
  /// every bounding rect that must contain the shadow needs (and, since the
  /// shadow legitimately falls outside the [GlassLayer], the amount its
  /// passes are allowed to paint past their own bounds).
  ///
  /// [EdgeInsets.zero] when the shadow is off, which is what keeps a
  /// shadowless layer's clips exactly what they were.
  EdgeInsets get shadowPadding {
    if (shadowIntensity <= 0) return EdgeInsets.zero;
    final r = math.max(shadowRadius, 0.0);
    return EdgeInsets.fromLTRB(
      math.max(r - shadowOffset.dx, 0),
      math.max(r - shadowOffset.dy, 0),
      math.max(r + shadowOffset.dx, 0),
      math.max(r + shadowOffset.dy, 0),
    );
  }

  @override
  bool operator ==(Object other) {
    return other is GlassOptions &&
        other.shineIntensity == shineIntensity &&
        other.shineDirection == shineDirection &&
        other.motionShine == motionShine &&
        other.bevelThickness == bevelThickness &&
        other.refractionIntensity == refractionIntensity &&
        other.childRefractionIntensity == childRefractionIntensity &&
        other.blurRadius == blurRadius &&
        other.blendRadius == blendRadius &&
        other.edgeTint == edgeTint &&
        other.shadowRadius == shadowRadius &&
        other.shadowIntensity == shadowIntensity &&
        other.shadowOffset == shadowOffset &&
        other.mode == mode;
  }

  @override
  int get hashCode => Object.hash(
    shineIntensity,
    shineDirection,
    motionShine,
    bevelThickness,
    refractionIntensity,
    childRefractionIntensity,
    blurRadius,
    blendRadius,
    edgeTint,
    shadowRadius,
    shadowIntensity,
    shadowOffset,
    mode,
  );
}
