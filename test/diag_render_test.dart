import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:just_liquid_glass/just_liquid_glass.dart';
import 'package:just_liquid_glass/src/packing.dart';

/// Not a regression test: renders diagnostic frames of the glass shader at
/// the worst-case merge moments (thin necks) so the output can be inspected.
/// Writes PNGs to DIAG_DIR if that environment variable is set; otherwise
/// does nothing.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const width = 360.0;
  const height = 240.0;

  Future<ui.Image> makeBackdrop() {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    const rect = ui.Rect.fromLTWH(0, 0, width, height);
    canvas.drawRect(
      rect,
      ui.Paint()
        ..shader = ui.Gradient.linear(
          rect.topLeft,
          rect.bottomRight,
          const [ui.Color(0xFF16325C), ui.Color(0xFFFF8C42)],
        ),
    );
    final stripe = ui.Paint()
      ..color = const ui.Color(0x88FFFFFF)
      ..strokeWidth = 3;
    for (var x = -height; x < width + height; x += 16) {
      canvas.drawLine(ui.Offset(x, 0), ui.Offset(x + height, height), stripe);
    }
    return recorder.endRecording().toImage(width.toInt(), height.toInt());
  }

  test('render merge-moment diagnostics', () async {
    final dir = Platform.environment['DIAG_DIR'];
    if (dir == null) return;

    final program = await ui.FragmentProgram.fromAsset('shaders/glass.frag');
    final backdrop = await makeBackdrop();

    // Distances chosen around first contact for r=55/45, blend 40.
    for (final (name, gap) in [
      ('touching', 145.0),
      ('neck_thin', 125.0),
      ('neck_mid', 105.0),
      ('merged', 80.0),
    ]) {
      final shader = program.fragmentShader();
      shader.setImageSampler(0, backdrop);
      shader.setFloat(0, width);
      shader.setFloat(1, height);
      shader.setFloat(2, 1.0); // dpr
      final blobs = [
        GlassBlob(
          center: ui.Offset(180 - gap / 2, 120),
          radii: const ui.Size(55, 55),
          tint: const ui.Color(0x40FFFFFF),
        ),
        GlassBlob(
          center: ui.Offset(180 + gap / 2, 120),
          radii: const ui.Size(45, 45),
          tint: const ui.Color(0x4000FFFF),
        ),
      ];
      shader.setFloat(3, blobs.length.toDouble());
      shader.setFloat(4, 40); // blendRadius
      shader.setFloat(5, 16); // bevelThickness
      shader.setFloat(6, 26); // refractionIntensity
      shader.setFloat(7, 0); // uOrigin: canvas at the render-target origin
      shader.setFloat(8, 0);
      final packed = packBlobs(blobs);
      for (var i = 0; i < packed.length; i++) {
        shader.setFloat(9 + i, packed[i]);
      }

      final flatProgram =
          await ui.FragmentProgram.fromAsset('shaders/flat.frag');
      final shine = flatProgram.fragmentShader();
      shine.setFloat(0, blobs.length.toDouble());
      shine.setFloat(1, 40); // blendRadius
      shine.setFloat(2, 2); // mode: shine
      shine.setFloat(3, 1); // dpr
      shine.setFloat(4, 0.5); // shineIntensity
      shine.setFloat(5, math.pi / 2); // shineDirection
      shine.setFloat(6, 16); // bevelThickness
      for (var i = 0; i < packed.length; i++) {
        shine.setFloat(7 + i, packed[i]);
      }

      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      const rect = ui.Rect.fromLTWH(0, 0, width, height);
      // Replicates the production composite: sharp backdrop below the
      // shader's premultiplied-coverage output (blur omitted — these frames
      // inspect merge geometry, and the shader no longer blurs in-pass).
      canvas.drawImage(backdrop, ui.Offset.zero, ui.Paint());
      canvas.drawRect(rect, ui.Paint()..shader = shader);
      canvas.drawRect(rect, ui.Paint()..shader = shine);
      final image =
          await recorder.endRecording().toImage(width.toInt(), height.toInt());
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      File('$dir/merge_$name.png')
          .writeAsBytesSync(png!.buffer.asUint8List());
    }
  });
}
