import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_refresh_rate_control/flutter_refresh_rate_control.dart';
import 'package:just_liquid_glass/just_liquid_glass.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  GlassLayer.precache();
  runApp(const DemoApp());
}

class DemoApp extends StatelessWidget {
  const DemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'just_liquid_glass demo',
      theme: ThemeData.dark(useMaterial3: true),
      home: const DemoPage(),
    );
  }
}

class DemoPage extends StatefulWidget {
  const DemoPage({super.key});

  @override
  State<DemoPage> createState() => _DemoPageState();
}

class _DemoPageState extends State<DemoPage>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 8),
  )..repeat();

  GlassMode _mode = GlassMode.glass;
  Offset? _pointer;
  String _refreshLabel = 'refresh rate: requesting…';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Request after the first frame so the Android window exists to apply
    // the preference to; requesting before runApp can silently no-op.
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _requestHighRefreshRate(),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The OS can drop the preference when the app is backgrounded.
    if (state == AppLifecycleState.resumed) _requestHighRefreshRate();
  }

  /// Asks the OS to hold the display's high refresh rate (120Hz). Paired
  /// with android:windowIsFrameRatePowerSavingsBalanced=false in styles.xml,
  /// which is required on non-Pixel/Samsung devices.
  Future<void> _requestHighRefreshRate() async {
    final control = FlutterRefreshRateControl();
    String label;
    try {
      final granted = await control.requestHighRefreshRate();
      final info = await control.getRefreshRateInfo();
      label = 'high refresh ${granted ? 'granted' : 'DENIED'} · $info';
    } catch (e) {
      label = 'refresh rate control unavailable: $e';
    }
    if (mounted) setState(() => _refreshLabel = label);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    super.dispose();
  }

  List<GlassBlob> _blobs(Size size, double t) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final orbit = math.min(cx, cy) * 0.45;
    final a = t * math.pi * 2;
    return [
      // Two orbiting circles that periodically fuse.
      GlassBlob(
        center: Offset(cx + math.cos(a) * orbit, cy + math.sin(a) * orbit),
        radii: const Size(70, 70),
        tint: const Color(0xB34FC3F7),
      ),
      GlassBlob(
        center: Offset(
          cx - math.cos(a) * orbit * 0.7,
          cy - math.sin(a) * orbit,
        ),
        radii: const Size(52, 52),
        tint: const Color(0xB3F06292),
      ),
      // A slowly rotating pill.
      GlassBlob(
        center: Offset(cx, cy),
        radii: const Size(110, 44),
        rotation: a / 2,
        tint: const Color(0xB300E5FF),
      ),
      // A sweeping progress-ring arc.
      GlassBlob(
        center: Offset(cx, size.height * 0.8),
        radii: const Size(64, 64),
        holeRadius: 40,
        startAngle: -math.pi / 2,
        endAngle:
            -math.pi / 2 +
            math.pi * 2 * (0.15 + 0.85 * (0.5 - 0.5 * math.cos(a))),
        tint: const Color(0xB3B388FF),
      ),
      // A blob that follows the pointer, fusing with whatever it touches.
      if (_pointer != null)
        GlassBlob(
          center: _pointer!,
          radii: const Size(20, 20),
          tint: const Color(0xB3FFF176),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: LayoutBuilder(
        builder: (context, constraints) {
          final size = constraints.biggest;
          return Listener(
            // Raw pointer events don't enter the gesture arena, so the blob
            // follows the finger while the backdrop grid still scrolls.
            behavior: HitTestBehavior.translucent,
            onPointerDown: (e) => setState(() => _pointer = e.localPosition),
            onPointerMove: (e) => setState(() => _pointer = e.localPosition),
            child: MouseRegion(
              onHover: (e) => setState(() => _pointer = e.localPosition),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // The backdrop: scrollable, and the thing the glass refracts.
                  const _Backdrop(),
                  // The glass floats above it. Its child is the on-glass
                  // content: clipped to the blobs and static while the
                  // backdrop scrolls beneath. IgnorePointer lets scroll
                  // gestures fall through to the backdrop grid.
                  AnimatedBuilder(
                    animation: _controller,
                    builder: (context, _) {
                      return GlassLayer(
                        blobs: _blobs(size, _controller.value),
                        options: GlassOptions(
                          mode: _mode,
                          blendRadius: 40,
                          refractionIntensity: 28,
                        ),
                        child: const IgnorePointer(child: _OnGlassContent()),
                      );
                    },
                  ),
                ],
              ),
            ),
          );
        },
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SegmentedButton<GlassMode>(
                segments: const [
                  ButtonSegment(value: GlassMode.glass, label: Text('Glass')),
                  ButtonSegment(value: GlassMode.flat, label: Text('Flat')),
                ],
                selected: {_mode},
                onSelectionChanged: (s) => setState(() => _mode = s.first),
              ),
              const SizedBox(height: 4),
              Text(
                ui.ImageFilter.isShaderFilterSupported
                    ? 'Backend supports glass mode (Impeller)'
                    : 'No shader backdrop filters here (Skia) — '
                          'glass falls back to flat',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              Text(
                _refreshLabel,
                style: Theme.of(context).textTheme.bodySmall,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Content that sits on the glass: a static grid of white glyphs, revealed
/// only where blobs pass over it (the GlassLayer masks it to the blobs).
class _OnGlassContent extends StatelessWidget {
  const _OnGlassContent();

  static const _icons = [
    Icons.favorite,
    Icons.star,
    Icons.bolt,
    Icons.cloud,
    Icons.music_note,
    Icons.anchor,
    Icons.pets,
    Icons.local_florist,
  ];

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 90,
      ),
      itemCount: 96,
      itemBuilder: (context, i) => Icon(
        _icons[i % _icons.length],
        size: 40,
        color: const Color(0xFFFFFFFF),
      ),
    );
  }
}

/// Busy multicolored content so refraction and blur are easy to see.
class _Backdrop extends StatelessWidget {
  const _Backdrop();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF16325C), Color(0xFF6A1B9A), Color(0xFFFF8C42)],
        ),
      ),
      child: GridView.builder(
        padding: const EdgeInsets.all(24),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 160,
          mainAxisSpacing: 16,
          crossAxisSpacing: 16,
        ),
        itemCount: 60,
        itemBuilder: (context, i) {
          final hue = (i * 47) % 360;
          return Card(
            color: HSLColor.fromAHSL(1, hue.toDouble(), 0.6, 0.5).toColor(),
            child: Center(
              child: Text(
                '$i',
                style: const TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
