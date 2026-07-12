import 'dart:math' as math;

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
    this.blurRadius = 17,
    this.blendRadius = 18,
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

  /// Backdrop blur radius in logical pixels (glass mode only). Realized as
  /// an engine gaussian with sigma = radius / 2 composed under the glass
  /// shader, so wide radii cost the same as narrow ones.
  final double blurRadius;

  /// Smooth-min merge radius: how far apart blobs start visually fusing,
  /// in logical pixels. Larger values are blobbier.
  final double blendRadius;

  /// Which rendering path to use; see [GlassMode].
  final GlassMode mode;

  @override
  bool operator ==(Object other) {
    return other is GlassOptions &&
        other.shineIntensity == shineIntensity &&
        other.shineDirection == shineDirection &&
        other.motionShine == motionShine &&
        other.bevelThickness == bevelThickness &&
        other.refractionIntensity == refractionIntensity &&
        other.blurRadius == blurRadius &&
        other.blendRadius == blendRadius &&
        other.mode == mode;
  }

  @override
  int get hashCode => Object.hash(
    shineIntensity,
    shineDirection,
    motionShine,
    bevelThickness,
    refractionIntensity,
    blurRadius,
    blendRadius,
    mode,
  );
}
