// Manual on-device check for GlassLayers that overhang the screen edges
// (e.g. a control centered on a thumb position at the edge). The composed
// backdrop filter's texture only holds valid data inside the clip trimmed to
// the render target; a regression here shows up as a dark bar hugging the
// screen edge on the glass rims (historically: right edge only, since
// textures anchor top-left). Run: flutter run -t lib/repro_main.dart and
// check all screen-edge rims stay artifact-free.
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:just_liquid_glass/just_liquid_glass.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  GlassLayer.precache();
  runApp(const Repro());
}

class _Backdrop extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFFFF3E0), Color(0xFFFFB74D)],
        ).createShader(rect),
    );
    final stripe = Paint()
      ..color = const Color(0x664527A0)
      ..strokeWidth = 8;
    for (var x = -size.height; x < size.width + size.height; x += 44) {
      canvas.drawLine(
          Offset(x, 0), Offset(x + size.height, size.height), stripe);
    }
  }

  @override
  bool shouldRepaint(_Backdrop oldDelegate) => false;
}

const _options = GlassOptions(blurRadius: 4);
const _tint = Color(0x40FFFFFF);

class Repro extends StatelessWidget {
  const Repro({super.key});

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: LayoutBuilder(builder: (context, constraints) {
        final s = constraints.biggest;
        return Stack(fit: StackFit.expand, children: [
          CustomPaint(painter: _Backdrop()),
          // GlassLayer OVERHANGING the LEFT screen edge (blob centered in the
          // layer, layer center on the edge) — the left-handed timer arc.
          Positioned(
            left: -150,
            top: 100,
            width: 300,
            height: 300,
            child: GlassLayer(
              blobs: const [
                GlassBlob(
                    center: Offset(110, 150), radii: Size(90, 90), tint: _tint),
              ],
              options: _options,
              child: const SizedBox.expand(),
            ),
          ),
          // GlassLayer OVERHANGING the RIGHT screen edge — the right-handed
          // timer arc case: half the layer is past the render target.
          Positioned(
            left: s.width - 150,
            top: 100,
            width: 300,
            height: 300,
            child: GlassLayer(
              blobs: const [
                GlassBlob(
                    center: Offset(190, 150), radii: Size(90, 90), tint: _tint),
              ],
              options: _options,
              child: const SizedBox.expand(),
            ),
          ),
          // Ring segment in a right-overhanging layer, like the timer arc.
          Positioned(
            left: s.width - 190,
            top: 500,
            width: 380,
            height: 380,
            child: GlassLayer(
              blobs: const [
                GlassBlob(
                  center: Offset(230, 190),
                  radii: Size(130, 130),
                  holeRadius: 70,
                  startAngle: math.pi / 2,
                  endAngle: 3 * math.pi / 2,
                  tint: _tint,
                ),
              ],
              options: _options,
              child: const SizedBox.expand(),
            ),
          ),
        ]);
      }),
    );
  }
}
