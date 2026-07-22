import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'glass_blob.dart';

/// Maximum number of blobs a single [GlassLayer] can render. Must match the
/// `uBlobs` array size in the shaders (5 vec4 per blob).
const int maxBlobs = 16;

/// Floats per blob in the packed uniform layout (5 vec4).
const int floatsPerBlob = 20;

/// Packs [blobs] into the flat float layout consumed by both shaders.
///
/// Layout per blob (matches `uBlobs` in glass.frag / flat.frag):
/// ```
/// [ 0] center.x   [ 1] center.y   [ 2] cos(rot)      [ 3] sin(rot)
/// [ 4] radii.x    [ 5] radii.y    [ 6] cornerRadius  [ 7] holeRadius (0 = none)
/// [ 8] axis.x     [ 9] axis.y     [10] cos(halfAp) (-2 = full)  [11] sin(halfAp)
/// [12] tint.r     [13] tint.g     [14] tint.b        [15] tint.a
/// [16] cornerContinuity            [17..19] reserved (0)
/// ```
/// A negative `[11]` marks a circular ring segment (circular radii, fully
/// rounded, with a hole and a sector): the shader renders those as an arc
/// with round end caps.
///
/// `[16]` blends the corner term from a circular arc (0) to a continuous
/// ("squircle") corner (1); see [GlassBlob.cornerContinuity] and sdBlob's
/// corner term. Ring segments are always circular regardless of continuity
/// (see [isCappedArc]).
Float32List packBlobs(List<GlassBlob> blobs) {
  assert(blobs.length <= maxBlobs,
      'GlassLayer supports at most $maxBlobs blobs, got ${blobs.length}');
  final data = Float32List(blobs.length * floatsPerBlob);
  for (var i = 0; i < blobs.length; i++) {
    final blob = blobs[i];
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
    // the canonical Euclidean field; the two corner norms only agree inside
    // the corner square, which those cases don't have. [17..19] stay 0.
    data[o + 16] = corner > 0
        ? blob.cornerContinuity.clamp(0.0, 1.0).toDouble()
        : 0;
  }
  return data;
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
  // Any corner continuity never takes the arc path: at a full corner radius
  // it forms a (partial) squircle rather than a circle, which the capped-arc
  // SDF (built on true circular symmetry) can't represent.
  return math.min(rx, ry) > 0 &&
      blob.cornerContinuity <= 0 &&
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
