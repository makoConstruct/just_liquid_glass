import 'dart:math' as math;
import 'dart:ui';

/// One full turn in radians.
const double _tau = math.pi * 2;

/// A single blob in a [GlassLayer]'s merged signed distance field.
///
/// The base shape is a rounded box with half-extents [radii], rotated by
/// [rotation] around [center]. From there:
///
/// * [cornerRadius] rounds the corners. The default of `double.infinity`
///   clamps to `min(radii.width, radii.height)`, producing a circle (equal
///   radii) or a stadium/pill (unequal radii). `0` gives a sharp rectangle.
///   [cornerContinuity] blends the corner profile from circular arcs toward
///   Apple-style continuous ("squircle") corners.
/// * [holeRadius] cuts a circular hole of that radius around the blob center,
///   turning the shape into a ring/annulus. The default of
///   `double.negativeInfinity` (or any value `<= 0`) means no hole.
/// * [startAngle]..[endAngle] clips the shape to an angular sector in the
///   blob's local (rotated) frame, measured in radians from the local +x axis
///   with positive angles toward +y (clockwise on screen). A sweep of [_tau]
///   or more means no clipping. Combined with [holeRadius] this produces arc
///   segments such as progress-ring sections.
///
/// [tint] colors the blob. In glass mode the tint is mixed over the refracted
/// backdrop with strength `tint.a`; in flat mode the blob is filled with the
/// tint directly (so a fully transparent tint makes the blob invisible in
/// flat mode).
///
/// ## Animating a blob out
///
/// Shrinking [radii] to zero does **not** remove a blob's influence: its
/// distance field degenerates to "distance to [center]", which still crosses
/// zero there — leaving a ~1px half-coverage dot, a shine speck, and a
/// smooth-min bulge on any neighbor surface within the layer's blend radius.
/// Deleting the blob from the list at that point pops those off in one frame.
///
/// For a continuous exit, keep animating the radii *past zero into negatives*
/// (e.g. `Size.square(-lift)`): a negative radius lifts the whole field
/// uniformly by `-min(radii)`, fading every effect out smoothly. The
/// smooth-min has compact support, so once `min(radii) <= -(blendRadius + 2)`
/// the blob has exactly zero influence and can be dropped from the list with
/// no visual change.
///
/// The exit lift is designed for plain (hole-less, full-sweep) blobs; a ring
/// segment's capped-arc field does not reduce to the point field at zero
/// radii, so animate its hole/sweep closed first.
class GlassBlob {
  const GlassBlob({
    required this.center,
    required this.radii,
    required this.tint,
    this.rotation = 0,
    this.cornerRadius = double.infinity,
    this.cornerContinuity = 0,
    this.holeRadius = double.negativeInfinity,
    this.startAngle = 0,
    this.endAngle = _tau,
  });

  /// Creates a pill-shaped blob rendered as a round-capped line of the given
  /// [thickness] running between [p1] and [p2].
  ///
  /// The pill's semicircular caps are centered on [p1] and [p2] (so it extends
  /// `thickness / 2` past each end, like [StrokeCap.round]), giving it a total
  /// length of `(p2 - p1).distance + thickness` and a height of [thickness].
  /// When `p1 == p2` this is a circle of diameter [thickness].
  ///
  /// [cornerContinuity] selects the cap curvature; the remaining parameters
  /// ([holeRadius], [startAngle], [endAngle]) forward to the default
  /// constructor for the rare case of clipping a line into a ring segment.
  factory GlassBlob.line(
    Offset p1,
    Offset p2, {
    required double thickness,
    required Color tint,
    double cornerContinuity = 0,
    double holeRadius = double.negativeInfinity,
    double startAngle = 0,
    double endAngle = _tau,
  }) {
    final Offset delta = p2 - p1;
    final double length = delta.distance;
    return GlassBlob(
      center: p1 + delta / 2,
      radii: Size((length + thickness) / 2, thickness / 2),
      tint: tint,
      rotation: length == 0 ? 0 : math.atan2(delta.dy, delta.dx),
      cornerContinuity: cornerContinuity,
      holeRadius: holeRadius,
      startAngle: startAngle,
      endAngle: endAngle,
    );
  }

  /// Center of the blob in the [GlassLayer]'s local logical coordinates.
  final Offset center;

  /// Half-extents of the blob (a "radius" per axis), in logical pixels.
  /// Negative values lift the field for a continuous exit animation; see
  /// "Animating a blob out" in the class docs.
  final Size radii;

  /// Blob color; see class docs for how it is applied per mode.
  final Color tint;

  /// Rotation around [center] in radians (positive is clockwise on screen).
  final double rotation;

  /// Corner rounding radius; clamped to `min(radii.width, radii.height)`.
  final double cornerRadius;

  /// Corner profile continuity, clamped to `0..1` when packed.
  ///
  /// At `0`, corners are circular arcs (constant curvature `1/cornerRadius`,
  /// matching [RRect]/standard rounded rectangles); curvature jumps
  /// discontinuously from 0 on the flat edge to `1/cornerRadius` at the
  /// tangent point. At `1`, corners follow a superellipse blend (exponent 4)
  /// whose curvature instead rises smoothly from 0 at the tangent point to a
  /// peak at the 45° point, matching Apple's continuous/"smooth" corner
  /// style; at `cornerRadius == min(radii)` this produces a true squircle
  /// rather than a circle.
  ///
  /// Values in between lerp the corner profile, so it can be animated — e.g.
  /// a fully rounded blob morphs from a true circle (`0`) to an
  /// Apple-squircle (`1`). Both profiles agree exactly on flat edges, so
  /// only the corner regions move.
  ///
  /// Has no effect on ring segments (see [holeRadius], [startAngle]): those
  /// always render with circular arcs.
  final double cornerContinuity;

  /// Radius of the circular hole cut around [center]; `<= 0` for none.
  final double holeRadius;

  /// Sector start angle in radians (local frame, 0 = local +x axis).
  final double startAngle;

  /// Sector end angle in radians; `endAngle - startAngle >= _tau` disables
  /// the sector clip.
  final double endAngle;

  @override
  bool operator ==(Object other) {
    return other is GlassBlob &&
        other.center == center &&
        other.radii == radii &&
        other.tint == tint &&
        other.rotation == rotation &&
        other.cornerRadius == cornerRadius &&
        other.cornerContinuity == cornerContinuity &&
        other.holeRadius == holeRadius &&
        other.startAngle == startAngle &&
        other.endAngle == endAngle;
  }

  @override
  int get hashCode => Object.hash(
    center,
    radii,
    tint,
    rotation,
    cornerRadius,
    cornerContinuity,
    holeRadius,
    startAngle,
    endAngle,
  );
}
