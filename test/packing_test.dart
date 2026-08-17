import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_liquid_glass/src/glass_blob.dart';
import 'package:just_liquid_glass/src/packing.dart';

void main() {
  const white = Color(0xFFFFFFFF);

  test('packs center, rotation, radii and tint', () {
    final data = packBlobs([
      const GlassBlob(
        center: Offset(10, 20),
        radii: Size(30, 40),
        rotation: math.pi / 2,
        cornerRadius: 5,
        tint: Color(0x80FF0000),
      ),
    ], defaultBlendRadius: 18);
    expect(data.length, floatsPerBlob);
    expect(data[0], 10);
    expect(data[1], 20);
    expect(data[2], closeTo(0, 1e-6)); // cos(pi/2)
    expect(data[3], closeTo(1, 1e-6)); // sin(pi/2)
    expect(data[4], 30);
    expect(data[5], 40);
    expect(data[6], 5);
    expect(data[12], closeTo(1, 1e-6));
    expect(data[13], closeTo(0, 1e-6));
    expect(data[14], closeTo(0, 1e-6));
    expect(data[15], closeTo(0.5, 0.01));
  });

  test('infinite cornerRadius clamps to min radius', () {
    final data = packBlobs([
      const GlassBlob(
        center: Offset.zero,
        radii: Size(30, 40),
        tint: white,
      ),
    ], defaultBlendRadius: 18);
    expect(data[6], 30);
  });

  test('negative radii (exit lift) pack corner = min radius, no throw', () {
    // Corner = min(radii) is what reduces the shader's rounded-box SDF to
    // the uniformly lifted point field |q| - min(radii).
    final data = packBlobs([
      const GlassBlob(
        center: Offset(10, 20),
        radii: Size(-26, -26),
        tint: white,
      ),
    ], defaultBlendRadius: 18);
    expect(data[4], -26);
    expect(data[5], -26);
    expect(data[6], -26);
    // An explicit cornerRadius must not resurrect the inverted clamp.
    final explicit = packBlobs([
      const GlassBlob(
        center: Offset.zero,
        radii: Size(-26, -26),
        cornerRadius: 8,
        tint: white,
      ),
    ], defaultBlendRadius: 18);
    expect(explicit[6], -26);
  });

  test('negative radii never select the capped-arc path and bound a point',
      () {
    const blob = GlassBlob(
      center: Offset(50, 60),
      radii: Size(-26, -26),
      holeRadius: 4,
      startAngle: 0,
      endAngle: math.pi,
      tint: white,
    );
    expect(isCappedArc(blob), isFalse);
    expect(blobBounds(blob), const Rect.fromLTRB(50, 60, 50, 60));
  });

  test('negative-infinity holeRadius encodes as 0 (disabled)', () {
    final data = packBlobs([
      const GlassBlob(center: Offset.zero, radii: Size(10, 10), tint: white),
    ], defaultBlendRadius: 18);
    expect(data[7], 0);
  });

  test('positive holeRadius passes through', () {
    final data = packBlobs([
      const GlassBlob(
        center: Offset.zero,
        radii: Size(10, 10),
        holeRadius: 4,
        tint: white,
      ),
    ], defaultBlendRadius: 18);
    expect(data[7], 4);
  });

  test('full-circle sweep disables sector clip', () {
    final data = packBlobs([
      const GlassBlob(center: Offset.zero, radii: Size(10, 10), tint: white),
    ], defaultBlendRadius: 18);
    expect(data[10], -2);
  });

  test('partial sweep encodes axis and half-aperture', () {
    final data = packBlobs([
      const GlassBlob(
        center: Offset.zero,
        radii: Size(10, 10),
        startAngle: 0,
        endAngle: math.pi,
        tint: white,
      ),
    ], defaultBlendRadius: 18);
    // mid = pi/2, half aperture = pi/2
    expect(data[8], closeTo(0, 1e-6));
    expect(data[9], closeTo(1, 1e-6));
    expect(data[10], closeTo(0, 1e-6));
    expect(data[11], closeTo(1, 1e-6));
  });

  test('circular ring segment encodes round-cap arc mode (negative sin)', () {
    final data = packBlobs([
      const GlassBlob(
        center: Offset.zero,
        radii: Size(50, 50),
        holeRadius: 30,
        startAngle: 0,
        endAngle: math.pi,
        tint: white,
      ),
    ], defaultBlendRadius: 18);
    expect(data[11], lessThan(0));
    expect(data[11], closeTo(-1, 1e-6)); // -sin(pi/2)
  });

  test('non-circular sector keeps hard cut (positive sin)', () {
    final data = packBlobs([
      const GlassBlob(
        center: Offset.zero,
        radii: Size(60, 40),
        holeRadius: 20,
        startAngle: 0,
        endAngle: math.pi,
        tint: white,
      ),
    ], defaultBlendRadius: 18);
    expect(data[11], greaterThan(0));
  });

  group('blobBounds', () {
    test('full circle bounds are the plain box', () {
      final r = blobBounds(const GlassBlob(
          center: Offset(100, 50), radii: Size(30, 30), tint: white));
      expect(r, const Rect.fromLTRB(70, 20, 130, 80));
    });

    test('half arc is not bounded as the full ring', () {
      // Sweep 0..pi covers only local +y; ra=40, rb=10.
      final r = blobBounds(const GlassBlob(
        center: Offset.zero,
        radii: Size(50, 50),
        holeRadius: 30,
        startAngle: 0,
        endAngle: math.pi,
        tint: white,
      ));
      expect(r.left, closeTo(-50, 1e-6));
      expect(r.right, closeTo(50, 1e-6));
      // Caps at angles 0 and pi extend rb=10 above the centerline endpoints.
      expect(r.top, closeTo(-10, 1e-6));
      expect(r.bottom, closeTo(50, 1e-6));
    });

    test('quarter pie sector is bounded to its quadrant', () {
      final r = blobBounds(const GlassBlob(
        center: Offset.zero,
        radii: Size(50, 50),
        startAngle: 0,
        endAngle: math.pi / 2,
        tint: white,
      ));
      expect(r.left, closeTo(0, 1e-6));
      expect(r.top, closeTo(0, 1e-6));
      expect(r.right, closeTo(50, 1e-6));
      expect(r.bottom, closeTo(50, 1e-6));
    });

    test('rotation rotates the tight bounds, not the full box', () {
      // Same half arc rotated by pi: now covers local -y side.
      final r = blobBounds(const GlassBlob(
        center: Offset.zero,
        radii: Size(50, 50),
        holeRadius: 30,
        rotation: math.pi,
        startAngle: 0,
        endAngle: math.pi,
        tint: white,
      ));
      expect(r.top, closeTo(-50, 1e-4));
      expect(r.bottom, closeTo(10, 1e-4));
    });
  });

  test('cornerContinuity packs into its own slot, clamped to 0..1', () {
    final data = packBlobs([
      const GlassBlob(
        center: Offset.zero,
        radii: Size(30, 40),
        cornerRadius: 5,
        cornerContinuity: 0.25,
        tint: white,
      ),
      const GlassBlob(
        center: Offset.zero,
        radii: Size(30, 40),
        cornerRadius: 5,
        cornerContinuity: 3,
        tint: white,
      ),
    ], defaultBlendRadius: 18);
    expect(data[6], 5); // cornerRadius stays plain (no sign encoding)
    expect(data[16], 0.25);
    expect(data[floatsPerBlob + 16], 1); // clamped
  });

  test('cornerContinuity defaults to 0 and is suppressed at zero corner', () {
    final data = packBlobs([
      const GlassBlob(
        center: Offset.zero,
        radii: Size(30, 40),
        tint: white,
      ),
      const GlassBlob(
        center: Offset.zero,
        radii: Size(30, 40),
        cornerRadius: 0,
        cornerContinuity: 1,
        tint: white,
      ),
    ], defaultBlendRadius: 18);
    expect(data[16], 0);
    // Sharp rectangles keep the canonical Euclidean field: continuity would
    // only alter the exterior field, not the silhouette.
    expect(data[floatsPerBlob + 6], 0);
    expect(data[floatsPerBlob + 16], 0);
  });

  test('cornerContinuity does not disqualify the capped-arc path', () {
    // A ring segment is fully rounded by construction, and there the
    // continuous profile *is* the circular one, so the round end caps stay
    // available at any continuity.
    const blob = GlassBlob(
      center: Offset.zero,
      radii: Size(50, 50),
      holeRadius: 30,
      startAngle: 0,
      endAngle: math.pi,
      cornerContinuity: 0.5,
      tint: white,
    );
    expect(isCappedArc(blob), isTrue);
    expect(cornerProfile(50, 50, 0.5), (reach: 50.0, exponent: 2.0));
  });

  group('cornerProfile', () {
    test('is the circular corner at zero continuity', () {
      expect(cornerProfile(100, 20, 0), (reach: 20.0, exponent: 2.0));
    });

    test('is the circular corner once the radius fills the box', () {
      // Impeller's rounded superellipse degenerates to a true circle at
      // radius == half-extent, so continuity has nothing left to spend.
      expect(cornerProfile(20, 20, 1), (reach: 20.0, exponent: 2.0));
    });

    test('reaches further along the edge as continuity rises', () {
      final quarter = cornerProfile(100, 20, 0.25);
      final full = cornerProfile(100, 20, 1);
      expect(quarter.reach, greaterThan(20));
      expect(quarter.reach, lessThan(full.reach));
      expect(quarter.exponent, greaterThan(2));
      expect(quarter.exponent, lessThan(full.exponent));
      expect(full.reach, closeTo(1.36 * 20, 1e-9));
    });

    test('keeps the 45° point on the circular corner at every continuity', () {
      // The defining constraint: the corner tip never moves, so a continuous
      // corner is directly comparable to a circular one of the same radius.
      for (final t in [0.0, 0.1, 0.5, 0.9, 1.0]) {
        for (final half in [21.0, 30.0, 100.0]) {
          final p = cornerProfile(half, 20, t);
          // Depth of the profile's own 45° point below the bounding box.
          final gap = p.reach * (1 - math.pow(2, -1 / p.exponent));
          expect(gap, closeTo(cornerGap * 20, 1e-9),
              reason: 'continuity $t, half-extent $half');
        }
      }
    });
  });

  test('distortion and range pack into their slots, defaulting to 0', () {
    final data = packBlobs([
      const GlassBlob(center: Offset.zero, radii: Size(10, 10), tint: white),
      const GlassBlob(
        center: Offset.zero,
        radii: Size(10, 10),
        distortion: 12,
        distortionRange: 40,
        tint: white,
      ),
    ], defaultBlendRadius: 18);
    expect(data[17], 0);
    expect(data[18], 0);
    expect(data[floatsPerBlob + 17], 12);
    expect(data[floatsPerBlob + 18], 40);
  });

  test('distortion blobs pack after rendered blobs regardless of order', () {
    final data = packBlobs([
      const GlassBlob(
        center: Offset(1, 0),
        radii: Size(10, 10),
        distortion: 12,
        distortionRange: 40,
        tint: white,
      ),
      const GlassBlob(center: Offset(2, 0), radii: Size(10, 10), tint: white),
    ], defaultBlendRadius: 18);
    // The rendered blob (center.x 2) lands in slot 0, the distorter after.
    expect(data[0], 2);
    expect(data[17], 0);
    expect(data[floatsPerBlob + 0], 1);
    expect(data[floatsPerBlob + 17], 12);
  });

  test('a distortion blob without a positive range asserts', () {
    expect(
        () => GlassBlob(
              center: Offset.zero,
              radii: const Size(10, 10),
              distortion: 12,
              tint: white,
            ),
        throwsA(isA<AssertionError>()));
  });

  test('blendRadius packs per blob, falling back to the layer default', () {
    final data = packBlobs([
      const GlassBlob(center: Offset.zero, radii: Size(10, 10), tint: white),
      const GlassBlob(
        center: Offset.zero,
        radii: Size(10, 10),
        blendRadius: 3,
        tint: white,
      ),
    ], defaultBlendRadius: 18);
    expect(data[19], 18);
    expect(data[floatsPerBlob + 19], 3);
  });

  test('blendRadius is clamped into the range the fold can carry', () {
    // A negative would invert the merge, and a value near the fold's own
    // sentinels would stop their clamps from saturating.
    final data = packBlobs([
      const GlassBlob(
        center: Offset.zero,
        radii: Size(10, 10),
        blendRadius: -5,
        tint: white,
      ),
      const GlassBlob(
        center: Offset.zero,
        radii: Size(10, 10),
        blendRadius: double.infinity,
        tint: white,
      ),
    ], defaultBlendRadius: 18);
    expect(data[19], 0);
    expect(data[floatsPerBlob + 19], maxBlendRadius);
  });

  test('rejects more than maxBlobs', () {
    final blobs = List.generate(
      maxBlobs + 1,
      (_) => const GlassBlob(
          center: Offset.zero, radii: Size(1, 1), tint: white),
    );
    expect(() => packBlobs(blobs, defaultBlendRadius: 18),
        throwsA(isA<AssertionError>()));
  });
}
