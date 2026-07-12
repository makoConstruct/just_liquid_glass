import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:just_liquid_glass/just_liquid_glass.dart';
import 'package:just_liquid_glass/src/packing.dart';

/// Renders glass.frag as a plain canvas shader with a manually supplied
/// backdrop texture. This is exactly the same program the Impeller
/// BackdropFilter path runs — only the engine-set uniforms (uSize, uTexture)
/// are provided by hand — so it verifies the full glass rendering
/// (SDF merge, refraction, tint, shine) on the CPU rasterizer.
///
/// In production the BackdropFilter composes an inner ImageFilter.blur, so
/// the shader's input texture is the pre-blurred backdrop and its
/// premultiplied-coverage output is composited srcOver onto the sharp one.
/// The goldens replicate that: sharp backdrop drawn first, shader (fed the
/// blurred texture) drawn over it.
// NOTE: these must be testWidgets, not plain test: in a plain test the
// golden comparator's async failure is swallowed and matchesGoldenFile
// "passes" against any image (verified with a red-square probe).
void main() {
  const width = 400.0;
  const height = 300.0;

  Future<ui.Image> makeBackdrop() {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    final rect = ui.Rect.fromLTWH(0, 0, width, height);
    canvas.drawRect(
      rect,
      ui.Paint()
        ..shader = ui.Gradient.linear(rect.topLeft, rect.bottomRight, const [
          ui.Color(0xFF16325C),
          ui.Color(0xFFFF8C42),
        ]),
    );
    // Diagonal stripes make refraction displacement visible.
    final stripe = ui.Paint()
      ..color = const ui.Color(0x66FFFFFF)
      ..strokeWidth = 4;
    for (var x = -height; x < width + height; x += 28) {
      canvas.drawLine(ui.Offset(x, 0), ui.Offset(x + height, height), stripe);
    }
    canvas.drawCircle(
      const ui.Offset(320, 80),
      36,
      ui.Paint()..color = const ui.Color(0xFFD32F2F),
    );
    return recorder.endRecording().toImage(width.toInt(), height.toInt());
  }

  // What the composed inner ImageFilter.blur hands the shader in production.
  Future<ui.Image> blurBackdrop(ui.Image sharp, double sigma) {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawImage(
      sharp,
      ui.Offset.zero,
      ui.Paint()
        ..imageFilter = ui.ImageFilter.blur(
          sigmaX: sigma,
          sigmaY: sigma,
          tileMode: ui.TileMode.clamp,
        ),
    );
    return recorder.endRecording().toImage(width.toInt(), height.toInt());
  }

  testWidgets('glass shader golden', (tester) async {
    final image = await tester.runAsync(() async {
      final program = await ui.FragmentProgram.fromAsset('shaders/glass.frag');
      final backdrop = await makeBackdrop();

      final shader = program.fragmentShader();
      shader.setFloat(0, width); // uSize (engine-set in production)
      shader.setFloat(1, height);
      shader.setFloat(2, 1.0); // uDpr
      const options = GlassOptions(
        blendRadius: 30,
        shineIntensity: 0.5,
        shineDirection: math.pi / 2,
        bevelThickness: 18,
        refractionIntensity: 30,
        blurRadius: 6,
      );
      final blobs = [
        const GlassBlob(
          center: ui.Offset(130, 150),
          radii: ui.Size(70, 70),
          tint: ui.Color(0xB3FFFFFF),
        ),
        const GlassBlob(
          center: ui.Offset(250, 130),
          radii: ui.Size(80, 36),
          rotation: 0.4,
          tint: ui.Color(0xB300FFFF),
        ),
        const GlassBlob(
          center: ui.Offset(300, 230),
          radii: ui.Size(50, 50),
          holeRadius: 28,
          startAngle: -math.pi / 2,
          endAngle: math.pi,
          tint: ui.Color(0xB3FF00FF),
        ),
      ];
      shader.setImageSampler(
        0,
        await blurBackdrop(backdrop, options.blurRadius / 2),
      );
      shader.setFloat(3, blobs.length.toDouble());
      shader.setFloat(4, options.blendRadius);
      shader.setFloat(5, options.bevelThickness);
      shader.setFloat(6, options.refractionIntensity);
      shader.setFloat(7, 0); // uOrigin: canvas at the render-target origin
      shader.setFloat(8, 0);
      shader.setFloat(9, 0); // uClip: whole canvas
      shader.setFloat(10, 0);
      shader.setFloat(11, width);
      shader.setFloat(12, height);
      final packed = packBlobs(blobs);
      for (var i = 0; i < packed.length; i++) {
        shader.setFloat(13 + i, packed[i]);
      }

      // The shine is a separate pass composited above the (masked) child in
      // the widget; replicate that compositing here so the golden shows the
      // complete glass look.
      final flatProgram = await ui.FragmentProgram.fromAsset(
        'shaders/flat.frag',
      );
      final shine = flatProgram.fragmentShader();
      shine.setFloat(0, blobs.length.toDouble());
      shine.setFloat(1, options.blendRadius);
      shine.setFloat(2, 2); // mode: shine
      shine.setFloat(3, 1); // dpr
      shine.setFloat(4, options.shineIntensity);
      shine.setFloat(5, options.shineDirection);
      shine.setFloat(6, options.bevelThickness);
      for (var i = 0; i < packed.length; i++) {
        shine.setFloat(7 + i, packed[i]);
      }

      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      const rect = ui.Rect.fromLTWH(0, 0, width, height);
      canvas.drawImage(backdrop, ui.Offset.zero, ui.Paint());
      canvas.drawRect(rect, ui.Paint()..shader = shader);
      canvas.drawRect(rect, ui.Paint()..shader = shine);
      return recorder.endRecording().toImage(width.toInt(), height.toInt());
    });

    await expectLater(image, matchesGoldenFile('goldens/glass_blobs.png'));
  });

  testWidgets('uOrigin shifts the field to match local blob coordinates', (
    tester,
  ) async {
    // A GlassLayer offset within the render target passes blob centers in its
    // own local frame plus its origin as uOrigin; the rendered field must
    // land where the same blob would with global centers and a zero origin.
    final bytes = await tester.runAsync(() async {
      final program = await ui.FragmentProgram.fromAsset('shaders/glass.frag');
      final backdrop = await makeBackdrop();
      const origin = ui.Offset(90, 40);

      Future<ui.Image> render(ui.Offset center, ui.Offset uOrigin) async {
        final shader = program.fragmentShader();
        shader.setImageSampler(0, backdrop);
        shader.setFloat(0, width);
        shader.setFloat(1, height);
        shader.setFloat(2, 1.0); // uDpr
        shader.setFloat(3, 1); // uBlobCount
        shader.setFloat(4, 30); // uBlendRadius
        shader.setFloat(5, 18); // uBevelThickness
        shader.setFloat(6, 30); // uRefraction
        shader.setFloat(7, uOrigin.dx);
        shader.setFloat(8, uOrigin.dy);
        // uClip is GlassLayer-local like the blob centers: the whole canvas
        // shifted by the origin, so both renders clamp to the same global rect.
        shader.setFloat(9, -uOrigin.dx);
        shader.setFloat(10, -uOrigin.dy);
        shader.setFloat(11, width - uOrigin.dx);
        shader.setFloat(12, height - uOrigin.dy);
        final packed = packBlobs([
          GlassBlob(
            center: center,
            radii: const ui.Size(70, 70),
            tint: const ui.Color(0xB3FFFFFF),
          ),
        ]);
        for (var i = 0; i < packed.length; i++) {
          shader.setFloat(13 + i, packed[i]);
        }
        final recorder = ui.PictureRecorder();
        ui.Canvas(recorder).drawRect(
          const ui.Rect.fromLTWH(0, 0, width, height),
          ui.Paint()..shader = shader,
        );
        return recorder.endRecording().toImage(width.toInt(), height.toInt());
      }

      final global = await render(const ui.Offset(200, 150), ui.Offset.zero);
      final local = await render(const ui.Offset(200, 150) - origin, origin);

      final globalBytes = (await global.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      final localBytes = (await local.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      return (global: globalBytes, local: localBytes);
    });

    expect(
      bytes!.local.buffer.asUint8List(),
      bytes.global.buffer.asUint8List(),
    );
  });
}
