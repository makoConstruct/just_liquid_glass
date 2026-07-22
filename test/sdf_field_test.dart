import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:just_liquid_glass/just_liquid_glass.dart';
import 'package:just_liquid_glass/src/packing.dart';

Future<ui.Image> _renderBlobs(List<GlassBlob> blobs) async {
  final program = await ui.FragmentProgram.fromAsset('shaders/flat.frag');
  final shader = program.fragmentShader();
  shader.setFloat(0, blobs.length.toDouble());
  shader.setFloat(1, 4); // blendRadius
  shader.setFloat(2, 0); // mode: tint fill
  shader.setFloat(3, 1); // dpr
  shader.setFloat(4, 0);
  shader.setFloat(5, 0);
  shader.setFloat(6, 1);
  final packed = packBlobs(blobs);
  for (var i = 0; i < packed.length; i++) {
    shader.setFloat(7 + i, packed[i]);
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
    shader.setFloat(1, 24); // blendRadius
    shader.setFloat(2, 0); // mode: tint fill
    shader.setFloat(3, 1); // dpr
    shader.setFloat(4, 0); // shineIntensity (unused in fill mode)
    shader.setFloat(5, 0); // shineDirection (unused in fill mode)
    shader.setFloat(6, 1); // bevelThickness (unused in fill mode)
    final packed = packBlobs(blobs);
    for (var i = 0; i < packed.length; i++) {
      shader.setFloat(7 + i, packed[i]);
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
      shader.setFloat(1, blend);
      shader.setFloat(2, 0); // mode: tint fill
      shader.setFloat(3, 1); // dpr
      shader.setFloat(4, 0); // shineIntensity (unused in fill mode)
      shader.setFloat(5, 0); // shineDirection (unused in fill mode)
      shader.setFloat(6, 1); // bevelThickness (unused in fill mode)
      final packed = packBlobs(blobs);
      for (var i = 0; i < packed.length; i++) {
        shader.setFloat(7 + i, packed[i]);
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

  test('continuous full-corner blob renders as a squircle, not a circle',
      () async {
    final image = await _renderBlobs([
      const GlassBlob(
        center: ui.Offset(100, 100),
        radii: ui.Size(60, 60),
        cornerRadius: 60,
        cornerContinuity: 1,
        tint: ui.Color(0xFF4FC3F7),
      ),
    ]);
    final data =
        (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;

    // Axis point: same extent as a circle of radius 60 (the corner formula
    // is exact on-axis regardless of exponent).
    expect(_alphaAt(data, 160, 100, 200), lessThan(128));
    expect(_alphaAt(data, 159, 100, 200), greaterThan(200));

    // Diagonal point q=(48,48): a circle of r=60 has |q|=67.9 there, ~8px
    // outside (well past the AA band). The n=4 superellipse |x|^4+|y|^4=r^4
    // reaches further out on the diagonal than the inscribed circle (it
    // interpolates toward a square as n grows past 2): corner value is
    // 48*2^(1/4) = 57.08, i.e. d = -2.9, safely inside. So (148,148) should
    // be opaque despite being outside the radius-60 circle -- the defining
    // visual trait of a "fuller" continuous corner.
    expect(_alphaAt(data, 148, 148, 200), greaterThan(200),
        reason: 'squircle diagonal should bulge past a same-radius circle');
  });

  test('fractional continuity morphs the silhouette between the two', () async {
    GlassBlob blob(double t) => GlassBlob(
          center: const ui.Offset(100, 100),
          radii: const ui.Size(60, 60),
          cornerRadius: 60,
          cornerContinuity: t,
          tint: const ui.Color(0xFF4FC3F7),
        );

    // Diagonal probes (fragments sample at +0.5, so pixel (144,144) probes
    // q = (44.5, 44.5)). Corner value there is 44.5 * mix(2^(1/2), 2^(1/4), t):
    //   t=0:   62.9 (d = +2.9, outside)   t=0.5: 57.9 (d = -2.1, inside)
    // and at pixel (148,148), q = (48.5, 48.5), 48.5 * the same mix:
    //   t=0.5: 63.1 (d = +3.1, outside)   t=1:   57.7 (d = -2.3, inside)
    // All margins clear the ~0.75px AA band, so the half-way silhouette lies
    // strictly between the circle and the squircle — continuity actually
    // interpolates rather than snapping to either profile.
    final circle = await _renderBlobs([blob(0)]);
    final half = await _renderBlobs([blob(0.5)]);
    final cD = (await circle.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    final hD = (await half.toByteData(format: ui.ImageByteFormat.rawRgba))!;

    expect(_alphaAt(cD, 144, 144, 200), 0);
    expect(_alphaAt(hD, 144, 144, 200), 255,
        reason: 'half continuity should bulge past the circle');
    expect(_alphaAt(hD, 148, 148, 200), 0,
        reason: 'half continuity should stay inside the full squircle');
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
}
