import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:just_liquid_glass/just_liquid_glass.dart';
import 'package:just_liquid_glass/src/packing.dart';

Future<ui.Image> _renderBlobs(List<GlassBlob> blobs) async {
  final program = await ui.FragmentProgram.fromAsset('shaders/flat.frag');
  final shader = program.fragmentShader();
  shader.setFloat(0, blobs.length.toDouble());
  shader.setFloat(1, 0); // mode: tint fill
  shader.setFloat(2, 1); // dpr
  shader.setFloat(3, 0);
  shader.setFloat(4, 0);
  shader.setFloat(5, 1);
  final packed = packBlobs(blobs, defaultBlendRadius: 4);
  for (var i = 0; i < packed.length; i++) {
    shader.setFloat(14 + i, packed[i]);
  }
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    const ui.Rect.fromLTWH(0, 0, 200, 200),
    ui.Paint()..shader = shader,
  );
  return recorder.endRecording().toImage(200, 200);
}

int _alphaAt(ByteData bytes, int x, int y, int w) =>
    bytes.getUint8((y * w + x) * 4 + 3);

// Regression test for two shader-portability bugs found on the SkSL backend:
//  * `break` inside the blob loop being silently miscompiled, letting the
//    zero-filled unused blob slots (whose degenerate SDF is 0 everywhere)
//    corrupt the merged field, and
//  * a 1e9 fold sentinel quantizing distances to the f32 ulp (64 at 1e9)
//    through mix().
// Either bug turns this single 55px circle into a fuzzy ~80px halo, so we
// assert exact interior/exterior alpha along a scanline through the center.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('single circle blob has an exact edge at its radius', () async {
    final program = await ui.FragmentProgram.fromAsset('shaders/flat.frag');
    final shader = program.fragmentShader();

    final blobs = [
      const GlassBlob(
        center: ui.Offset(100, 100),
        radii: ui.Size(55, 55),
        tint: ui.Color(0xFF4FC3F7),
      ),
    ];
    shader.setFloat(0, blobs.length.toDouble());
    shader.setFloat(1, 0); // mode: tint fill
    shader.setFloat(2, 1); // dpr
    shader.setFloat(3, 0); // shineIntensity (unused in fill mode)
    shader.setFloat(4, 0); // shineDirection (unused in fill mode)
    shader.setFloat(5, 1); // bevelThickness (unused in fill mode)
    final packed = packBlobs(blobs, defaultBlendRadius: 24);
    for (var i = 0; i < packed.length; i++) {
      shader.setFloat(14 + i, packed[i]);
    }

    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawRect(
      const ui.Rect.fromLTWH(0, 0, 220, 200),
      ui.Paint()..shader = shader,
    );
    final image = await recorder.endRecording().toImage(220, 200);
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final bytes = data!.buffer.asUint8List();

    int alphaAt(int x) => bytes[(100 * 220 + x) * 4 + 3];

    // Fully opaque well inside the radius-55 circle centered at x=100.
    for (final x in [100, 120, 140, 153]) {
      expect(alphaAt(x), 255, reason: 'interior pixel x=$x');
    }
    // Fully transparent outside (beyond the ~1.5px AA band at x=155).
    for (final x in [158, 170, 180, 200]) {
      expect(alphaAt(x), 0, reason: 'exterior pixel x=$x');
    }
  });

  test('negative radii (exit lift) remove all influence at the blend radius',
      () async {
    // Pins the continuous-exit contract from the GlassBlob docs: a 0-radius
    // blob still renders a dot and bulges neighbors, and continuing the
    // radius to -(blendRadius + 2) is pixel-identical to removing the blob.
    final program = await ui.FragmentProgram.fromAsset('shaders/flat.frag');
    const blend = 24.0;

    const neighbor = GlassBlob(
      center: ui.Offset(100, 100),
      radii: ui.Size(55, 55),
      tint: ui.Color(0xFF4FC3F7),
    );

    Future<Uint8List> render(List<GlassBlob> blobs) async {
      final shader = program.fragmentShader();
      shader.setFloat(0, blobs.length.toDouble());
      shader.setFloat(1, 0); // mode: tint fill
      shader.setFloat(2, 1); // dpr
      shader.setFloat(3, 0); // shineIntensity (unused in fill mode)
      shader.setFloat(4, 0); // shineDirection (unused in fill mode)
      shader.setFloat(5, 1); // bevelThickness (unused in fill mode)
      final packed = packBlobs(blobs, defaultBlendRadius: blend);
      for (var i = 0; i < packed.length; i++) {
        shader.setFloat(14 + i, packed[i]);
      }
      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder).drawRect(
        const ui.Rect.fromLTWH(0, 0, 220, 200),
        ui.Paint()..shader = shader,
      );
      final image = await recorder.endRecording().toImage(220, 200);
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      return data!.buffer.asUint8List();
    }

    // On a pixel center (fragments sample at +0.5), so the residual dot of
    // the 0-radius field (d = 0 exactly at the center) lands on a sample.
    GlassBlob exiting(double radius) => GlassBlob(
          center: const ui.Offset(175.5, 100.5),
          radii: ui.Size.square(radius),
          tint: const ui.Color(0xFF4FC3F7),
        );

    final alone = await render([neighbor]);
    final zeroRadius = await render([neighbor, exiting(0)]);
    final lifted = await render([neighbor, exiting(-(blend + 2))]);

    int alphaAt(Uint8List bytes, int x) => bytes[(100 * 220 + x) * 4 + 3];

    // Radius 0 is NOT gone: residual dot at its center, bulge on the
    // neighbor (20px from the surface, within the blend radius).
    expect(alphaAt(zeroRadius, 175), greaterThan(0),
        reason: 'residual dot at the 0-radius blob center');
    expect(zeroRadius, isNot(equals(alone)),
        reason: '0-radius blob still influences the image');

    // Lifted past the blend radius: bit-identical to the blob being absent.
    expect(lifted, equals(alone));
  });

  test('continuous full-corner blob stays a circle', () async {
    // Impeller's rounded superellipse degenerates to a true circle once the
    // radius fills the box, so continuity must be a no-op here -- the
    // opposite of a squircle. Anything else would also break the capped-arc
    // path, which assumes exact circular symmetry (see isCappedArc).
    GlassBlob blob(double t) => GlassBlob(
          center: const ui.Offset(100, 100),
          radii: const ui.Size(60, 60),
          cornerRadius: 60,
          cornerContinuity: t,
          tint: const ui.Color(0xFF4FC3F7),
        );
    final circular = await _renderBlobs([blob(0)]);
    final continuous = await _renderBlobs([blob(1)]);
    final a = (await circular.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    final b =
        (await continuous.toByteData(format: ui.ImageByteFormat.rawRgba))!;

    // The continuous arm still runs (pow(x, 2.0) rather than length()), so
    // the AA band rounds a step or two differently; the silhouette itself
    // must not move, which the total coverage pins to a fraction of a pixel.
    var areaA = 0.0, areaB = 0.0;
    for (var y = 0; y < 200; y++) {
      for (var x = 0; x < 200; x++) {
        expect((_alphaAt(b, x, y, 200) - _alphaAt(a, x, y, 200)).abs(),
            lessThanOrEqualTo(4),
            reason: 'pixel ($x, $y)');
        areaA += _alphaAt(a, x, y, 200) / 255;
        areaB += _alphaAt(b, x, y, 200) / 255;
      }
    }
    // 8px^2 over a 377px perimeter is a mean radial shift under 0.02px; a
    // real profile change of 0.001 * r would move it by 22.
    expect(areaB, closeTo(areaA, 8));

    // And it really is the radius-60 circle: the diagonal at |q| = 68.6 is
    // far outside it, where the old squircle profile used to bulge.
    expect(_alphaAt(b, 148, 148, 200), 0);
    expect(_alphaAt(b, 159, 100, 200), greaterThan(200));
  });

  test('continuity interpolates the corner between circular and continuous',
      () async {
    // Room to spare (half-extent 3x the radius), so the profile runs out to
    // its full 1.36x reach.
    GlassBlob blob(double t) => GlassBlob(
          center: const ui.Offset(100, 100),
          radii: const ui.Size(60, 60),
          cornerRadius: 20,
          cornerContinuity: t,
          tint: const ui.Color(0xFF4FC3F7),
        );

    /// Sub-pixel y of the top silhouette on column [x], from the AA ramp.
    Future<double> edgeY(double t, int x) async {
      final image = await _renderBlobs([blob(t)]);
      final data =
          (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      var cover = 0.0;
      for (var y = 30; y < 100; y++) {
        cover += _alphaAt(data, x, y, 200) / 255;
      }
      return 100 - cover;
    }

    // Mid-edge, far outside any corner: all three sit on the box edge, which
    // also calibrates the AA ramp's own bias out of the corner probes below.
    final flat = await edgeY(1, 100);
    expect(flat, closeTo(await edgeY(0, 100), 0.02));

    // 0.75 radii in from the corner, where circular and continuous differ
    // most: the circular arc has dipped 0.635px below the edge, ours 1.0px.
    final circular = await edgeY(0, 145) - flat;
    final half = await edgeY(0.5, 145) - flat;
    final full = await edgeY(1, 145) - flat;

    // Circular: the radius-20 arc at 0.75r in, 0.77px below the box edge.
    // Continuous: 1.14px, the same corner reaching further along the edge.
    expect(circular, closeTo(0.76, 0.05));
    expect(full, closeTo(1.14, 0.05));
    // Half-way lies strictly between: continuity interpolates the profile
    // rather than snapping to either end.
    expect(half, greaterThan(circular + 0.1));
    expect(half, lessThan(full - 0.1));
  });

  group('distortion blobs', () {
    // Shared geometry: the radius-55 circle from the first test (edge at
    // x = 155 on the y = 100 scanline) with a small distorter to its right.
    const neighbor = GlassBlob(
      center: ui.Offset(100, 100),
      radii: ui.Size(55, 55),
      tint: ui.Color(0xFF4FC3F7),
    );

    test('pushes a neighbor surface outward without rendering itself',
        () async {
      final image = await _renderBlobs([
        neighbor,
        // Red tint: blends into the displaced surface at the kernel weight,
        // never anywhere the kernel has faded out.
        const GlassBlob(
          center: ui.Offset(185, 100),
          radii: ui.Size(10, 10),
          distortion: 12,
          distortionRange: 40,
          tint: ui.Color(0xFFFF0000),
        ),
      ]);
      final data =
          (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;

      // Pixels outside the undistorted silhouette (the first test pins them
      // at alpha 0) are now opaque: at (158.5, 100.5) the field is +3.5 and
      // the bump is 12 * kernel(16.5/40) = 7.6, so ~ -4.1; at (162.5, 100.5)
      // +7.5 against a bump of 9.2, so ~ -1.7. Both clear the AA band.
      expect(_alphaAt(data, 158, 100, 200), 255,
          reason: 'surface should be pushed outward toward the distorter');
      expect(_alphaAt(data, 162, 100, 200), 255);

      // The far side of the circle is beyond the range: untouched.
      expect(_alphaAt(data, 42, 100, 200), 0);
      expect(_alphaAt(data, 50, 100, 200), 255);

      // The distorter itself does not render: at its center the merged
      // field is ~30 and the full-strength bump only 12.
      expect(_alphaAt(data, 185, 100, 200), 0,
          reason: 'distortion blob must not render itself');

      // Its tint mixes in at the kernel weight: the bulged pixel sits at
      // s = 0.63, so cyan -> red lands around (190, 72) — clearly
      // red-shifted — while the far interior (kernel weight 0) stays cyan.
      final o = (100 * 200 + 158) * 4;
      expect(data.getUint8(o), greaterThan(150), reason: 'red at the bulge');
      expect(data.getUint8(o + 1), lessThan(120), reason: 'green at the bulge');
      final c = (100 * 200 + 100) * 4;
      expect(data.getUint8(c), lessThan(100), reason: 'red at the center');
      expect(data.getUint8(c + 1), greaterThan(150),
          reason: 'green at the center');
    });

    test('negative distortion dents a neighbor inward', () async {
      final image = await _renderBlobs([
        neighbor,
        const GlassBlob(
          center: ui.Offset(185, 100),
          radii: ui.Size(10, 10),
          distortion: -12,
          distortionRange: 40,
          tint: ui.Color(0xFFFF0000),
        ),
      ]);
      final data =
          (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;

      // (153.5, 100.5) is 1.5px inside the plain circle but the dent lifts
      // the field by 5.3 there; deeper in at (140.5, 100.5) the kernel has
      // nearly faded (bump 0.5 against a field of -14.5).
      expect(_alphaAt(data, 153, 100, 200), 0,
          reason: 'edge should be dented inward');
      expect(_alphaAt(data, 140, 100, 200), 255,
          reason: 'dent should stay local to the facing edge');
    });

    test('out of range, the image is bit-identical to the blob being absent',
        () async {
      // The distorter's surface sits 20px past the neighbor's edge, so a
      // range of 15 keeps the kernel's support 5px clear of the AA band:
      // the bump is identically zero everywhere coverage is nonzero, and
      // everywhere else both images saturate to exact transparency.
      final alone = await _renderBlobs([neighbor]);
      final distorted = await _renderBlobs([
        neighbor,
        const GlassBlob(
          center: ui.Offset(185, 100),
          radii: ui.Size(10, 10),
          distortion: 12,
          distortionRange: 15,
          tint: ui.Color(0xFFFF0000),
        ),
      ]);
      final a = (await alone.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      final b =
          (await distorted.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      expect(b.buffer.asUint8List(), equals(a.buffer.asUint8List()));
    });

    test('distorter tint survives being listed before the rendered blob',
        () async {
      // The shader's tint fold is sequential, so without the packing
      // reorder a rendered blob after the distorter would wipe its tint
      // (while the order-independent push kept working) — the confusing
      // "distortion but no tint" failure. Both orders must render
      // identically.
      const distorter = GlassBlob(
        center: ui.Offset(185, 100),
        radii: ui.Size(10, 10),
        distortion: 12,
        distortionRange: 40,
        tint: ui.Color(0xFFFF0000),
      );
      final last = await _renderBlobs([neighbor, distorter]);
      final first = await _renderBlobs([distorter, neighbor]);
      final a = (await last.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      final b = (await first.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      expect(b.buffer.asUint8List(), equals(a.buffer.asUint8List()));

      // And the tint is actually present, not merely consistent.
      final o = (100 * 200 + 158) * 4;
      expect(b.getUint8(o), greaterThan(150), reason: 'red at the bulge');
    });

    test('distorter tint also comes through the glass shader', () async {
      // Same scene as the flat-mode tint probe, but rendered with
      // glass.frag driven directly as a canvas shader (the golden-test
      // harness): a solid gray backdrop, refraction/blur/edgeTint off, so
      // the output color is mix(gray, tint.rgb, tint.a) and tint blending
      // is cleanly measurable.
      final program = await ui.FragmentProgram.fromAsset('shaders/glass.frag');
      final shader = program.fragmentShader();

      const w = 220, h = 200;
      final bgRecorder = ui.PictureRecorder();
      ui.Canvas(bgRecorder).drawRect(
        const ui.Rect.fromLTWH(0, 0, 220, 200),
        ui.Paint()..color = const ui.Color(0xFF808080),
      );
      final backdrop = await bgRecorder.endRecording().toImage(w, h);

      final blobs = [
        const GlassBlob(
          center: ui.Offset(100, 100),
          radii: ui.Size(55, 55),
          tint: ui.Color(0xB34FC3F7),
        ),
        const GlassBlob(
          center: ui.Offset(185, 100),
          radii: ui.Size(10, 10),
          distortion: 12,
          distortionRange: 40,
          tint: ui.Color(0xFFFF0000),
        ),
      ];
      shader.setImageSampler(0, backdrop);
      shader.setFloat(0, w.toDouble()); // uSize
      shader.setFloat(1, h.toDouble());
      shader.setFloat(2, 1); // uDpr
      shader.setFloat(3, blobs.length.toDouble());
      shader.setFloat(4, 17); // uBevelThickness
      shader.setFloat(5, 0); // uRefraction
      shader.setFloat(6, 0); // uOrigin
      shader.setFloat(7, 0);
      shader.setFloat(8, 0); // uClip: whole canvas
      shader.setFloat(9, 0);
      shader.setFloat(10, w.toDouble());
      shader.setFloat(11, h.toDouble());
      for (var i = 0; i < 4; i++) {
        shader.setFloat(12 + i, 0); // uEdgeTint: disabled
      }
      final packed = packBlobs(blobs, defaultBlendRadius: 4);
      for (var i = 0; i < packed.length; i++) {
        shader.setFloat(20 + i, packed[i]);
      }

      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder).drawRect(
        const ui.Rect.fromLTWH(0, 0, 220, 200),
        ui.Paint()..shader = shader,
      );
      final image = await recorder.endRecording().toImage(w, h);
      final data =
          (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;

      // The bulge exists (opaque past the plain silhouette) and is
      // red-shifted; the interior far from the distorter keeps the
      // neighbor's cyan-over-gray; the distorter itself renders nothing.
      expect(_alphaAt(data, 158, 100, w), 255);
      final o = (100 * w + 158) * 4;
      expect(data.getUint8(o), greaterThan(150), reason: 'red at the bulge');
      expect(data.getUint8(o + 1), lessThan(120),
          reason: 'green at the bulge');
      final c = (100 * w + 100) * 4;
      expect(data.getUint8(c), lessThan(100), reason: 'red at the center');
      expect(data.getUint8(c + 1), greaterThan(150),
          reason: 'green at the center');
      expect(_alphaAt(data, 185, 100, w), 0,
          reason: 'distorter must not render in glass mode either');
    });

    test('a distortion blob alone renders nothing', () async {
      final image = await _renderBlobs([
        const GlassBlob(
          center: ui.Offset(100, 100),
          radii: ui.Size(40, 40),
          distortion: 12,
          distortionRange: 40,
          tint: ui.Color(0xFFFF0000),
        ),
      ]);
      final data =
          (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      for (final x in [60, 100, 140]) {
        expect(_alphaAt(data, x, 100, 200), 0, reason: 'pixel x=$x');
      }
    });
  });

  test('continuous partial corner matches circular on the flat edge',
      () async {
    // Off the corner region entirely (well within a long flat edge), a
    // continuous corner blob must render identically to a circular one:
    // the corner formula collapses to the same value there.
    final circular = await _renderBlobs([
      const GlassBlob(
        center: ui.Offset(100, 100),
        radii: ui.Size(80, 40),
        cornerRadius: 10,
        tint: ui.Color(0xFF4FC3F7),
      ),
    ]);
    final continuous = await _renderBlobs([
      const GlassBlob(
        center: ui.Offset(100, 100),
        radii: ui.Size(80, 40),
        cornerRadius: 10,
        cornerContinuity: 1,
        tint: ui.Color(0xFF4FC3F7),
      ),
    ]);
    final a =
        (await circular.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    final b =
        (await continuous.toByteData(format: ui.ImageByteFormat.rawRgba))!;

    for (final x in [40, 60, 100, 140, 160]) {
      expect(_alphaAt(b, x, 60, 200), _alphaAt(a, x, 60, 200),
          reason: 'flat-edge pixel x=$x should match exactly');
    }

    // Near the corner (close to the right edge), the two should differ,
    // showing continuous mode is actually doing something there.
    var anyDiffer = false;
    for (final x in [172, 175, 178]) {
      for (final y in [65, 70, 75]) {
        if (_alphaAt(b, x, y, 200) != _alphaAt(a, x, y, 200)) {
          anyDiffer = true;
        }
      }
    }
    expect(anyDiffer, isTrue,
        reason: 'corner region should visibly differ between styles');
  });

  group('per-blob blendRadius', () {
    // Two circles with a 4px gap between their surfaces, at a layer default
    // wide enough to bridge it.
    const left = GlassBlob(
      center: ui.Offset(70, 100),
      radii: ui.Size(30, 30),
      tint: ui.Color(0xFF4FC3F7),
    );
    const right = GlassBlob(
      center: ui.Offset(134, 100),
      radii: ui.Size(30, 30),
      tint: ui.Color(0xFF4FC3F7),
    );

    Future<ByteData> render(List<GlassBlob> blobs) async {
      final program = await ui.FragmentProgram.fromAsset('shaders/flat.frag');
      final shader = program.fragmentShader();
      shader.setFloat(0, blobs.length.toDouble());
      shader.setFloat(1, 0); // mode: tint fill
      shader.setFloat(2, 1); // dpr
      shader.setFloat(3, 0);
      shader.setFloat(4, 0);
      shader.setFloat(5, 1);
      final packed = packBlobs(blobs, defaultBlendRadius: 24);
      for (var i = 0; i < packed.length; i++) {
        shader.setFloat(14 + i, packed[i]);
      }
      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder).drawRect(
        const ui.Rect.fromLTWH(0, 0, 200, 200),
        ui.Paint()..shader = shader,
      );
      final image = await recorder.endRecording().toImage(200, 200);
      return (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    }

    // Midway between the two surfaces: covered only by the merge bridge.
    int bridge(ByteData bytes) => _alphaAt(bytes, 102, 100, 200);

    test('null takes the layer default, and 0 opts a blob out of merging',
        () async {
      expect(bridge(await render([left, right])), 255,
          reason: 'both on the layer default should fuse across the gap');

      // The junction merges over min(k) of its two blobs, so *either* one
      // going crisp is enough to break the bridge.
      expect(bridge(await render([left.crisp, right])), 0);
      expect(bridge(await render([left, right.crisp])), 0);
    });

    test('a raised radius is still capped by its neighbor', () async {
      // Not a request for more goo: the neighbor is on the default, so the
      // junction stays exactly the default's.
      final raised = await render([left.blend(200), right]);
      final plain = await render([left, right]);
      for (var i = 0; i < plain.lengthInBytes; i++) {
        expect(raised.getUint8(i), plain.getUint8(i),
            reason: 'byte $i should be unchanged by the raised radius');
      }
    });

    test('the junction width does not depend on blob order', () async {
      // The fold is sequential, so a rule that merged each blob at its own
      // radius would put a *bridge* in one of these two lists and not the
      // other. min() is symmetric, so both stay crisp.
      final forward = await render([left.crisp, right]);
      final reverse = await render([right, left.crisp]);
      expect(bridge(forward), 0);
      expect(bridge(reverse), 0);

      // What order does still cost is a rounding residue: smin() is
      // commutative in exact arithmetic but mix(a, b, h) and mix(b, a, 1 - h)
      // are not the same float, so AA pixels can land one step apart. (With
      // three surfaces inside one blend band there is a real, if small,
      // difference on top of that: the polynomial smin is not associative —
      // which predates per-blob radii and applies to a single global one just
      // as much.)
      var worst = 0;
      for (var i = 0; i < forward.lengthInBytes; i++) {
        final d = (reverse.getUint8(i) - forward.getUint8(i)).abs();
        if (d > worst) worst = d;
      }
      expect(worst, lessThanOrEqualTo(1));
    });

    test('a crisp blob does not sharpen junctions it is not part of',
        () async {
      // The accumulator carries the *locally* dominant blob's radius, so a
      // crisp blob far away leaves this pair alone.
      const far = GlassBlob(
        center: ui.Offset(20, 20),
        radii: ui.Size(10, 10),
        tint: ui.Color(0xFF4FC3F7),
        blendRadius: 0,
      );
      expect(bridge(await render([far, left, right])), 255);
      expect(bridge(await render([left, far, right])), 255);
    });
  });
}

extension on GlassBlob {
  GlassBlob get crisp => blend(0);

  GlassBlob blend(double radius) => GlassBlob(
        center: center,
        radii: radii,
        tint: tint,
        blendRadius: radius,
      );
}
