import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'glass_blob.dart';

/// Maximum number of blobs a single [GlassLayer] can render. Must match the
/// `uBlobs` array size in the shaders (6 vec4 per blob).
const int maxBlobs = 16;

/// Floats per blob in the packed uniform layout (6 vec4).
const int floatsPerBlob = 24;

/// Packs [blobs] into the flat float layout consumed by both shaders.
///
/// Layout per blob (matches `uBlobs` in glass.frag / flat.frag):
/// ```
/// [ 0] center.x   [ 1] center.y   [ 2] cos(rot)      [ 3] sin(rot)
/// [ 4] radii.x    [ 5] radii.y    [ 6] cornerRadius  [ 7] holeRadius (0 = none)
/// [ 8] axis.x     [ 9] axis.y     [10] cos(halfAp) (-2 = full)  [11] sin(halfAp)
/// [12] tint.r     [13] tint.g     [14] tint.b        [15] tint.a
/// [16] cornerContinuity  [17] distortion  [18] distortionRange  [19] reserved
/// [20] reachX     [21] exponentX  [22] reachY        [23] exponentY
/// ```
/// A negative `[11]` marks a circular ring segment (circular radii, fully
/// rounded, with a hole and a sector): the shader renders those as an arc
/// with round end caps.
///
/// `[16]` is non-zero when the corner profile is continuous at all, which is
/// the shader's cheap branch out of the superellipse math; `[20..23]` carry
/// the profile itself (see [cornerProfile]), already lerped by the
/// continuity, so a `0` continuity packs the plain circular corner
/// (`reach == cornerRadius`, `exponent == 2`) on both axes.
///
/// A non-zero `[17]` marks a distortion blob: the shader excludes it from
/// the smooth-min merge (so it never renders) and instead subtracts a bump
/// of up to `[17]` from the merged field, fading over `[18]` past the blob's
/// surface — and mixes its tint at that same kernel weight; see
/// [GlassBlob.distortion].
Float32List packBlobs(List<GlassBlob> blobs) {
  assert(blobs.length <= maxBlobs,
      'GlassLayer supports at most $maxBlobs blobs, got ${blobs.length}');
  // Distortion blobs pack after every rendered blob regardless of list
  // position: the shader's tint fold is sequential, and a rendered blob
  // processed after a distorter remixes at h ~ 1 wherever it exists,
  // wiping the distorter's tint. Everything else about a distorter is
  // order-independent (its merge is a no-op and its bump is a sum), so the
  // stable partition changes nothing but the tint.
  final ordered = [
    for (final blob in blobs)
      if (blob.distortion == 0) blob,
    for (final blob in blobs)
      if (blob.distortion != 0) blob,
  ];
  final data = Float32List(ordered.length * floatsPerBlob);
  for (var i = 0; i < ordered.length; i++) {
    final blob = ordered[i];
    final o = i * floatsPerBlob;

    data[o + 0] = blob.center.dx;
    data[o + 1] = blob.center.dy;
    data[o + 2] = math.cos(blob.rotation);
    data[o + 3] = math.sin(blob.rotation);

    final rx = blob.radii.width;
    final ry = blob.radii.height;
    data[o + 4] = rx;
    data[o + 5] = ry;
    // Negative radii are the exit-lift encoding (see GlassBlob.radii docs):
    // corner = maxCorner makes the rounded-box SDF reduce to
    // |q| - min(radii), the point field lifted uniformly above zero.
    final maxCorner = math.min(rx, ry);
    final corner = maxCorner <= 0 || blob.cornerRadius.isNaN
        ? maxCorner
        : blob.cornerRadius.clamp(0.0, maxCorner).toDouble();
    data[o + 6] = corner;
    data[o + 7] =
        (blob.holeRadius.isFinite && blob.holeRadius > 0) ? blob.holeRadius : 0;

    final sweep = (blob.endAngle - blob.startAngle).abs();
    if (sweep >= (math.pi * 2) - 1e-6) {
      data[o + 8] = 1;
      data[o + 9] = 0;
      data[o + 10] = -2; // sector clip disabled
      data[o + 11] = 0;
    } else {
      final mid = (blob.startAngle + blob.endAngle) / 2;
      final half = sweep / 2;
      data[o + 8] = math.cos(mid);
      data[o + 9] = math.sin(mid);
      data[o + 10] = math.cos(half);
      // Circular ring segments get round end caps by default; the negative
      // sin(halfAperture) selects the capped-arc SDF in the shader.
      final sinHalf = math.max(math.sin(half), 1e-6);
      data[o + 11] = isCappedArc(blob) ? -sinHalf : sinHalf;
    }

    data[o + 12] = blob.tint.r;
    data[o + 13] = blob.tint.g;
    data[o + 14] = blob.tint.b;
    data[o + 15] = blob.tint.a;

    // Suppressed at corner <= 0 so sharp rectangles and exit-lift blobs keep
    // the canonical Euclidean field: there is no corner square to reshape.
    final continuity =
        corner > 0 ? blob.cornerContinuity.clamp(0.0, 1.0).toDouble() : 0.0;
    data[o + 16] = continuity;
    data[o + 17] = blob.distortion;
    data[o + 18] = math.max(blob.distortionRange, 0);

    // One profile per axis, kept whole within one vec4 for the shader: the
    // corner's reach along an edge depends on that edge's own half-extent (a
    // wide pill gets a long tail lengthwise and an exactly circular end cap).
    final x = cornerProfile(rx, corner, continuity);
    final y = cornerProfile(ry, corner, continuity);
    data[o + 20] = x.reach; // [19] stays 0
    data[o + 21] = x.exponent;
    data[o + 22] = y.reach;
    data[o + 23] = y.exponent;
  }
  return data;
}

/// Depth of the corner's 45° point below the bounding box, in units of the
/// corner radius — `1 - cos(pi/4)`.
///
/// A circular arc and Flutter's [RSuperellipse] agree here *exactly*: Impeller
/// pins the rounded superellipse's corner midpoint to the circular one
/// (`RoundSuperellipseParam::kGapFactor`) and spends the continuity entirely
/// on how the curve reaches the flat edges. So does [cornerProfile].
const double cornerGap = 0.29289321881;

/// Longest a continuous corner reaches along an edge, in units of the corner
/// radius, and how fast it gets there as the edge grows past the radius.
///
/// Fitted (see test/rsuperellipse_test.dart) against Flutter's real shape.
const double _reachMax = 1.36;
const double _reachSlope = 0.5;

/// The corner curve along one axis: a superellipse of half-extent [reach] and
/// degree [exponent], both in the corner's local frame.
typedef CornerProfile = ({double reach, double exponent});

/// Corner profile for an edge of half-extent [halfExtent], a [cornerRadius]
/// and a [continuity] in `0..1`.
///
/// At `continuity == 1` this is a *fit* to Flutter's [RSuperellipse]
/// (`RoundedSuperellipseBorder`, the Apple/SwiftUI `.continuous` shape), not
/// that shape. Impeller builds its corner from a superellipse segment patched
/// with a circular arc; that has no closed-form distance, and a piecewise port
/// would seam the field by 5-8% of its own value right through the bevel band,
/// so this uses a single superellipse pinned to the same 45° point
/// ([cornerGap]) instead.
///
/// The fit stays within `0.0066 * cornerRadius` of perpendicular deviation
/// (bounded by test/rsuperellipse_test.dart against `dart:ui` itself). It is
/// worst about three quarters of a radius in from the corner, where it
/// over-dips by ~0.007 of the radius, and past ~1.3 radii it has rejoined the
/// flat edge while Flutter's still has a very shallow tail. For scale, the
/// whole circular-to-continuous difference is only ~0.015 of the radius, so
/// this reproduces the effect but not its exact distribution. Fitting `reach`
/// and `exponent` freely per ratio would only reach 0.0056, so the residual is
/// the curve family's, not a tuning miss.
///
/// Both endpoints are exact rather than approximate: `continuity == 0` gives
/// the circular corner, and so does `cornerRadius == halfExtent` at *any*
/// continuity — matching Impeller, whose rounded superellipse degenerates to
/// a true circle once the radius fills the box.
CornerProfile cornerProfile(
    double halfExtent, double cornerRadius, double continuity) {
  if (cornerRadius <= 0 || continuity <= 0) {
    return (reach: cornerRadius, exponent: 2);
  }
  // Reach grows with the room available past the radius, then saturates.
  final full =
      math.min(_reachMax, 1 + _reachSlope * (halfExtent / cornerRadius - 1));
  final sigma = 1 + (full - 1) * continuity;
  // Degree that puts the curve's 45° point back on the circular one. Exact at
  // sigma == 1 (exponent 2, a circular arc), and near-linear in sigma above.
  final exponent =
      sigma <= 1 ? 2.0 : math.ln2 / -math.log(1 - cornerGap / sigma);
  return (reach: sigma * cornerRadius, exponent: exponent);
}

/// Effective corner radius after the clamp applied during packing.
double _effectiveCorner(GlassBlob blob) {
  final maxCorner = math.min(blob.radii.width, blob.radii.height);
  return maxCorner <= 0 || blob.cornerRadius.isNaN
      ? maxCorner
      : blob.cornerRadius.clamp(0.0, maxCorner).toDouble();
}

double _effectiveHole(GlassBlob blob) =>
    (blob.holeRadius.isFinite && blob.holeRadius > 0) ? blob.holeRadius : 0;

double _sweep(GlassBlob blob) => (blob.endAngle - blob.startAngle).abs();

/// Whether the blob renders as a circular ring segment with round end caps.
bool isCappedArc(GlassBlob blob) {
  final rx = blob.radii.width;
  final ry = blob.radii.height;
  // Non-positive radii (exit lift) always take the rounded-box path.
  // Continuity is not excluded: everything below also forces the corner
  // radius to fill the box, where the continuous profile *is* the circle
  // (see [cornerProfile]), so the capped-arc SDF stays exact.
  return math.min(rx, ry) > 0 &&
      _sweep(blob) < (math.pi * 2) - 1e-6 &&
      _effectiveHole(blob) > 0 &&
      (rx - ry).abs() <= 1e-3 &&
      _effectiveCorner(blob) >= math.min(rx, ry) - 1e-3;
}

/// Whether local angle [angle] falls within the blob's sweep interval.
bool _angleInSweep(GlassBlob blob, double angle) {
  final s = math.min(blob.startAngle, blob.endAngle);
  final range = _sweep(blob);
  return (angle - s) % (math.pi * 2) <= range;
}

/// Tight axis-aligned bounds of a single blob in layer coordinates,
/// accounting for rotation, sectors and (capped) arcs — a half arc is not
/// bounded as if it were the full ring.
Rect blobBounds(GlassBlob blob) {
  // Negative radii (exit lift) collapse to a point at the center; any
  // residual bulge stays within the blend radius, which the GlassLayer's
  // bounds padding already covers.
  final rx = math.max(blob.radii.width, 0.0);
  final ry = math.max(blob.radii.height, 0.0);

  // Bounds in the blob's local (unrotated) frame.
  Rect local;
  if (_sweep(blob) >= (math.pi * 2) - 1e-6) {
    local = Rect.fromLTRB(-rx, -ry, rx, ry);
  } else {
    // Candidate extreme angles: the sweep endpoints plus any axis extreme
    // (0, pi/2, pi, 3pi/2) that lies inside the sweep.
    final angles = <double>[blob.startAngle, blob.endAngle];
    for (var k = 0; k < 4; k++) {
      final a = k * math.pi / 2;
      if (_angleInSweep(blob, a)) angles.add(a);
    }

    if (isCappedArc(blob)) {
      // Centerline arc of radius ra, inflated by the half-thickness rb —
      // the inflation covers the round end caps exactly.
      final rOut = math.min(rx, ry);
      final hole = _effectiveHole(blob);
      final ra = (rOut + hole) / 2;
      final rb = (rOut - hole) / 2;
      var l = double.infinity, t = double.infinity;
      var r = double.negativeInfinity, b = double.negativeInfinity;
      for (final a in angles) {
        final x = ra * math.cos(a);
        final y = ra * math.sin(a);
        l = math.min(l, x);
        t = math.min(t, y);
        r = math.max(r, x);
        b = math.max(b, y);
      }
      local = Rect.fromLTRB(l - rb, t - rb, r + rb, b + rb);
    } else {
      // Hard-cut sector: the shape lies inside both the base box and the
      // wedge clipped to the box's circumradius.
      final circum = math.sqrt(rx * rx + ry * ry);
      var l = 0.0, t = 0.0, r = 0.0, b = 0.0; // wedge apex at the origin
      for (final a in angles) {
        final x = circum * math.cos(a);
        final y = circum * math.sin(a);
        l = math.min(l, x);
        t = math.min(t, y);
        r = math.max(r, x);
        b = math.max(b, y);
      }
      local = Rect.fromLTRB(l, t, r, b)
          .intersect(Rect.fromLTRB(-rx, -ry, rx, ry));
    }
  }

  // Rotate the local rect's corners into layer space.
  final c = math.cos(blob.rotation);
  final s = math.sin(blob.rotation);
  var l = double.infinity, t = double.infinity;
  var r = double.negativeInfinity, b = double.negativeInfinity;
  for (final corner in [
    Offset(local.left, local.top),
    Offset(local.right, local.top),
    Offset(local.left, local.bottom),
    Offset(local.right, local.bottom),
  ]) {
    final x = c * corner.dx - s * corner.dy + blob.center.dx;
    final y = s * corner.dx + c * corner.dy + blob.center.dy;
    l = math.min(l, x);
    t = math.min(t, y);
    r = math.max(r, x);
    b = math.max(b, y);
  }
  return Rect.fromLTRB(l, t, r, b);
}
