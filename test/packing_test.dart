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
    ]);
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
    ]);
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
    ]);
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
    ]);
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
    ]);
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
    ]);
    expect(data[7], 4);
  });

  test('full-circle sweep disables sector clip', () {
    final data = packBlobs([
      const GlassBlob(center: Offset.zero, radii: Size(10, 10), tint: white),
    ]);
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
    ]);
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
    ]);
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
    ]);
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

  test('continuous corner style packs cornerRadius negated', () {
    final data = packBlobs([
      const GlassBlob(
        center: Offset.zero,
        radii: Size(30, 40),
        cornerRadius: 5,
        cornerStyle: CornerStyle.continuous,
        tint: white,
      ),
    ]);
    expect(data[6], -5);
  });

  test('continuous corner style with zero radius stays non-negative', () {
    final data = packBlobs([
      const GlassBlob(
        center: Offset.zero,
        radii: Size(30, 40),
        cornerRadius: 0,
        cornerStyle: CornerStyle.continuous,
        tint: white,
      ),
    ]);
    expect(data[6], 0);
  });

  test('continuous corner style never selects the capped-arc path', () {
    const blob = GlassBlob(
      center: Offset.zero,
      radii: Size(50, 50),
      holeRadius: 30,
      startAngle: 0,
      endAngle: math.pi,
      cornerStyle: CornerStyle.continuous,
      tint: white,
    );
    expect(isCappedArc(blob), isFalse);
  });

  test('rejects more than maxBlobs', () {
    final blobs = List.generate(
      maxBlobs + 1,
      (_) => const GlassBlob(
          center: Offset.zero, radii: Size(1, 1), tint: white),
    );
    expect(() => packBlobs(blobs), throwsA(isA<AssertionError>()));
  });
}
