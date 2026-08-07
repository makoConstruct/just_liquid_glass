import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_liquid_glass/just_liquid_glass.dart';

const _background = Color(0xFF101010);
const _panel = GlassBlob(
  center: Offset(80, 80),
  radii: Size(40, 40),
  tint: Color(0xFF4FC3F7),
);
const _red = GlassBlob(
  center: Offset(220, 220),
  radii: Size(30, 30),
  tint: Color(0xFFFF0000),
);

Widget _harness(GlobalKey<GlassLayerState> key,
    {List<GlassBlob> blobs = const [], Widget child = const SizedBox()}) {
  return Center(
    child: RepaintBoundary(
      key: const ValueKey('boundary'),
      child: SizedBox(
        width: 300,
        height: 300,
        child: ColoredBox(
          color: _background,
          child: GlassLayer(
            key: key,
            blobs: blobs,
            options: const GlassOptions(mode: GlassMode.flat, blendRadius: 12),
            child: child,
          ),
        ),
      ),
    ),
  );
}

/// Reads the boundary's pixels; (x, y) are layer-local logical px.
Future<ByteData> _snapshot(WidgetTester tester) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('boundary')));
  final data = await tester.runAsync(() async {
    final image = await boundary.toImage();
    return image.toByteData(format: ui.ImageByteFormat.rawRgba);
  });
  return data!;
}

int _red8(ByteData d, int x, int y) => d.getUint8((y * 300 + x) * 4);
int _green8(ByteData d, int x, int y) => d.getUint8((y * 300 + x) * 4 + 1);

/// Calls [GlassLayerState.replaceBlob] from didUpdateWidget — i.e. during
/// the build phase — which the repaint-level replaceBlob must tolerate.
class _BuildTimeInjector extends StatefulWidget {
  const _BuildTimeInjector({required this.layerKey, this.blob});
  final GlobalKey<GlassLayerState> layerKey;
  final GlassBlob? blob;

  @override
  State<_BuildTimeInjector> createState() => _BuildTimeInjectorState();
}

class _BuildTimeInjectorState extends State<_BuildTimeInjector> {
  GlassBlob? _current;

  @override
  void didUpdateWidget(_BuildTimeInjector oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.blob, widget.blob)) {
      widget.layerKey.currentState!.replaceBlob(_current, widget.blob);
      _current = widget.blob;
    }
  }

  @override
  Widget build(BuildContext context) => const SizedBox();
}

void main() {
  testWidgets('replaceBlob repaints the injected blob without a rebuild',
      (tester) async {
    await tester.runAsync(GlassLayer.precache);
    final key = GlobalKey<GlassLayerState>();
    await tester.pumpWidget(_harness(key, blobs: const [_panel]));

    var shot = await _snapshot(tester);
    expect(_red8(shot, 220, 220), lessThan(50),
        reason: 'nothing at the injection site yet');

    key.currentState!.replaceBlob(null, _red);
    await tester.pump();
    shot = await _snapshot(tester);
    expect(_red8(shot, 220, 220), greaterThan(200));
    expect(_green8(shot, 220, 220), lessThan(50));

    key.currentState!.replaceBlob(_red, null);
    await tester.pump();
    shot = await _snapshot(tester);
    expect(_red8(shot, 220, 220), lessThan(50), reason: 'removed again');
  });

  testWidgets('replaceBlob is callable from didUpdateWidget (build phase)',
      (tester) async {
    await tester.runAsync(GlassLayer.precache);
    final key = GlobalKey<GlassLayerState>();
    await tester.pumpWidget(_harness(key,
        blobs: const [_panel], child: _BuildTimeInjector(layerKey: key)));

    await tester.pumpWidget(_harness(key,
        blobs: const [_panel],
        child: _BuildTimeInjector(layerKey: key, blob: _red)));
    expect(tester.takeException(), isNull);

    final shot = await _snapshot(tester);
    expect(_red8(shot, 220, 220), greaterThan(200),
        reason: 'blob injected mid-build should paint that same frame');
  });

  testWidgets('first injection into a bare layer builds the overlay',
      (tester) async {
    // A layer with no blobs and no builder short-circuits to the bare
    // child; the first injected blob (and removal of the last) is the
    // structural rebuild path of replaceBlob.
    await tester.runAsync(GlassLayer.precache);
    final key = GlobalKey<GlassLayerState>();
    await tester.pumpWidget(_harness(key));

    key.currentState!.replaceBlob(null, _red);
    await tester.pump();
    var shot = await _snapshot(tester);
    expect(_red8(shot, 220, 220), greaterThan(200));

    key.currentState!.replaceBlob(_red, null);
    await tester.pump();
    shot = await _snapshot(tester);
    expect(_red8(shot, 220, 220), lessThan(50));
  });

  testWidgets('GlassSwell injects declaratively and removes at zero',
      (tester) async {
    await tester.runAsync(GlassLayer.precache);
    final key = GlobalKey<GlassLayerState>();

    Widget swell(double distortion) => _harness(key,
        blobs: const [_panel],
        child: Center(
          child: SizedBox(
            width: 100,
            height: 40,
            child: GlassSwell(
              layerKey: key,
              distortion: distortion,
              distortionRange: 30,
              tint: const Color(0xFFFF0000),
              child: const SizedBox.expand(),
            ),
          ),
        ));

    await tester.pumpWidget(swell(0));
    await tester.pump(); // post-frame first sync: zero distortion, no blob
    expect(key.currentState!.injectedBlobs, isEmpty);

    await tester.pumpWidget(swell(8));
    final blob = key.currentState!.injectedBlobs.single;
    expect(blob.distortion, 8);
    expect(blob.distortionRange, 30);
    expect(blob.center, const Offset(150, 150));
    expect(blob.radii, const Size(50, 20));

    await tester.pumpWidget(swell(3));
    expect(key.currentState!.injectedBlobs.single.distortion, 3);

    await tester.pumpWidget(swell(0));
    expect(key.currentState!.injectedBlobs, isEmpty);

    // Removed on dispose (deferred one frame).
    await tester.pumpWidget(swell(8));
    expect(key.currentState!.injectedBlobs, hasLength(1));
    await tester.pumpWidget(_harness(key, blobs: const [_panel]));
    await tester.pump();
    expect(key.currentState!.injectedBlobs, isEmpty);
  });

  testWidgets('GlassPressSwell swells on press and leaves after release',
      (tester) async {
    await tester.runAsync(GlassLayer.precache);
    final key = GlobalKey<GlassLayerState>();
    await tester.pumpWidget(_harness(key,
        blobs: const [_panel],
        child: Center(
          child: SizedBox(
            width: 100,
            height: 40,
            child: GlassPressSwell(
              layerKey: key,
              tint: const Color(0xFFFF0000),
              child: const ColoredBox(color: Color(0xFF222222)),
            ),
          ),
        )));

    final gesture = await tester
        .startGesture(tester.getCenter(find.byType(GlassPressSwell)));
    await tester.pump(); // first frame only starts the press ticker
    await tester.pump(const Duration(milliseconds: 60));
    final mid = key.currentState!.injectedBlobs.single;
    expect(mid.distortion, greaterThan(0));

    // An immediate release: the swell must hold for minimumHold before the
    // down swing even begins.
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 50));
    expect(key.currentState!.injectedBlobs, hasLength(1));

    // Past the hold and the fall, the blob is gone entirely.
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 250));
    expect(key.currentState!.injectedBlobs, isEmpty);
  });
}
