import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_liquid_glass/just_liquid_glass.dart';

/// Bright diagonal stripes: obviously recognizable content that should be
/// visible only inside the blob silhouette.
class _Stripes extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFFFFFFFF)
      ..strokeWidth = 6;
    for (var x = -size.height; x < size.width + size.height; x += 24) {
      canvas.drawLine(Offset(x, 0), Offset(x + size.height, size.height),
          paint);
    }
  }

  @override
  bool shouldRepaint(_Stripes oldDelegate) => false;
}

void main() {
  testWidgets(
      'flat mode: tint fills below, child stripes clipped inside blobs',
      (tester) async {
    await tester.runAsync(GlassLayer.precache);

    final blobs = [
      // Two overlapping circles with different tints: exercises smooth-min
      // merging and tint blending.
      const GlassBlob(
        center: Offset(110, 100),
        radii: Size(55, 55),
        tint: Color(0xB34FC3F7),
      ),
      const GlassBlob(
        center: Offset(200, 120),
        radii: Size(40, 40),
        tint: Color(0xB3F06292),
      ),
      // Rotated sharp-cornered rectangle.
      const GlassBlob(
        center: Offset(300, 90),
        radii: Size(60, 25),
        rotation: 0.5,
        cornerRadius: 0,
        tint: Color(0xB3FFF176),
      ),
      // Ring segment (270 degrees): should get round end caps by default.
      const GlassBlob(
        center: Offset(160, 230),
        radii: Size(50, 50),
        holeRadius: 30,
        startAngle: 0,
        endAngle: 3 * math.pi / 2,
        tint: Color(0xB381C784),
      ),
      // Semi-transparent stadium.
      const GlassBlob(
        center: Offset(310, 230),
        radii: Size(70, 30),
        tint: Color(0xB300E5FF),
      ),
    ];

    await tester.pumpWidget(
      Center(
        child: RepaintBoundary(
          child: SizedBox(
            width: 400,
            height: 300,
            child: ColoredBox(
              color: const Color(0xFF1A1A2E),
              child: GlassLayer(
                blobs: blobs,
                options: const GlassOptions(
                  mode: GlassMode.flat,
                  blendRadius: 24,
                ),
                child: CustomPaint(painter: _Stripes()),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    await expectLater(
      find.byType(GlassLayer),
      matchesGoldenFile('goldens/flat_blobs.png'),
    );
  });
}
