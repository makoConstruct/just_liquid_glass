// Static showcase grid for README screenshots:
//
//   flutter run -t lib/showcase_main.dart
//
// Every cell is its own GlassLayer so per-layer options (shine, blend
// radius) can differ between cells. Nothing animates; frame it and shoot.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_liquid_glass/just_liquid_glass.dart';

/// Flip to [GlassMode.flat] to screenshot the flat fallback instead.
const GlassMode _mode = GlassMode.glass;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Hide the status/navigation bars for clean screenshots.
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  GlassLayer.precache();
  runApp(const ShowcaseApp());
}

class ShowcaseApp extends StatelessWidget {
  const ShowcaseApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'just_liquid_glass showcase',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: const ShowcasePage(),
    );
  }
}

// Blob palette: white, transparent, grey, black, grey-green.
// "White" is a very light grey so it still reads on the near-white backdrop.
const Color _white = Color(0xCCE2E2E2);
const Color _clear = Color(0x00FFFFFF);
const Color _grey = Color(0x99777777);
const Color _black = Color(0x99000000);
const Color _sage = Color(0xB3778866);

class ShowcasePage extends StatelessWidget {
  const ShowcasePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          const _Backdrop(),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _row([
                    _Cell('rect', _rect),
                    _Cell('rounded rect', _roundedRect),
                    _Cell(
                      'flat opaque',
                      _flatFused,
                      options: const GlassOptions(
                        mode: GlassMode.flat,
                        blendRadius: 18,
                      ),
                    ),
                  ]),
                  _row([
                    _Cell('composition', _composition),
                    _Cell('arc', _arc),
                    _Cell('rotation', _rotated),
                  ]),
                  _row([
                    _Cell('tints', _tints, options: _options(blendRadius: 8)),
                    _Cell(
                      'shine',
                      _shineBlob,
                      options: _options(shineIntensity: 0.7),
                    ),
                    _Cell(
                      'no shine',
                      _shineBlob,
                      options: _options(shineIntensity: 0),
                    ),
                  ]),
                  _row([
                    _Cell(
                      'viscosity: low',
                      _pair,
                      options: _options(blendRadius: 4),
                    ),
                    _Cell(
                      'viscosity: medium',
                      _pair,
                      options: _options(blendRadius: 18),
                    ),
                    _Cell(
                      'viscosity: high',
                      _pair,
                      options: _options(blendRadius: 44),
                    ),
                  ]),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(List<Widget> cells) {
    return Row(
      children: [
        for (final cell in cells)
          Expanded(child: AspectRatio(aspectRatio: 1, child: cell)),
      ],
    );
  }
}

GlassOptions _options({double shineIntensity = 0.4, double blendRadius = 18}) {
  return GlassOptions(
    mode: _mode,
    shineIntensity: shineIntensity,
    blendRadius: blendRadius,
    blurRadius: 4,
    bevelThickness: 12,
    refractionIntensity: 18,
  );
}

// ---------------------------------------------------------------------------
// Blob builders. Each receives the cell's size; m is its smaller side.

List<GlassBlob> _rect(Size s, double m) => [
  GlassBlob(
    center: s.center(Offset.zero),
    radii: Size(m * 0.36, m * 0.26),
    cornerRadius: 0,
    tint: _white,
  ),
];

List<GlassBlob> _roundedRect(Size s, double m) => [
  GlassBlob(
    center: s.center(Offset.zero),
    radii: Size(m * 0.36, m * 0.26),
    cornerRadius: m * 0.1,
    tint: _grey,
  ),
];

/// Two fused circles in flat mode with fully opaque tints.
List<GlassBlob> _flatFused(Size s, double m) => [
  GlassBlob(
    center: s.center(Offset(-m * 0.13, -m * 0.06)),
    radii: Size.square(m * 0.2),
    tint: const Color(0xFF1A1A1A),
  ),
  GlassBlob(
    center: s.center(Offset(m * 0.13, m * 0.08)),
    radii: Size.square(m * 0.16),
    tint: const Color(0xFF778866),
  ),
];

/// A rounded rect merging into a circle, cupped by a thick quarter arc at
/// its below-right — one connected liquid form.
List<GlassBlob> _composition(Size s, double m) {
  final circle = s.center(Offset(m * 0.06, m * 0.02));
  final r = m * 0.18;
  return [
    GlassBlob(
      center: circle - Offset(m * 0.3, m * 0.24),
      radii: Size(m * 0.22, m * 0.14),
      cornerRadius: m * 0.12,
      tint: _sage,
    ),
    GlassBlob(center: circle, radii: Size.square(r), tint: _white),
    // Concentric with the circle, sweeping the below-right quadrant.
    GlassBlob(
      center: circle,
      radii: Size.square(r + m * 0.2),
      holeRadius: r + m * 0.06,
      startAngle: 0,
      endAngle: math.pi / 2,
      tint: _black,
    ),
  ];
}

List<GlassBlob> _arc(Size s, double m) => [
  GlassBlob(
    center: s.center(Offset.zero),
    radii: Size.square(m * 0.34),
    holeRadius: m * 0.18,
    startAngle: -math.pi / 2,
    endAngle: -math.pi / 2 + math.pi * 2 * 0.7,
    tint: _sage,
  ),
];

List<GlassBlob> _rotated(Size s, double m) => [
  // A transparent tint is pure glass: refraction and shine only.
  GlassBlob(
    center: s.center(Offset.zero),
    radii: Size(m * 0.4, m * 0.16),
    rotation: -math.pi / 6,
    tint: _clear,
  ),
];

List<GlassBlob> _tints(Size s, double m) => [
  // Slightly overlapping so the chain merges into one surface.
  for (final (i, tint) in const [_white, _black, _sage].indexed)
    GlassBlob(
      center: s.center(Offset((i - 1) * m * 0.28, 0)),
      radii: Size.square(m * 0.15),
      tint: tint,
    ),
];

List<GlassBlob> _shineBlob(Size s, double m) => [
  GlassBlob(
    center: s.center(Offset.zero),
    radii: Size.square(m * 0.3),
    tint: _clear,
  ),
];

List<GlassBlob> _pair(Size s, double m) => [
  // Edge gap of 0.06m: separate at low blend, necked at medium, fused
  // at high.
  for (final dx in const [-0.2, 0.2])
    GlassBlob(
      center: s.center(Offset(m * dx, 0)),
      radii: Size.square(m * 0.17),
      tint: _grey,
    ),
];

/// One labeled showcase cell with its own [GlassLayer].
class _Cell extends StatelessWidget {
  const _Cell(this.label, this.blobs, {GlassOptions? options})
    : options = options ?? const GlassOptions(mode: _mode);

  final String label;
  final List<GlassBlob> Function(Size size, double m) blobs;
  final GlassOptions options;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final size = constraints.biggest;
              final m = size.shortestSide;
              return GlassLayer(
                blobs: blobs(size, m),
                options: options,
                child: const SizedBox.expand(),
              );
            },
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: Colors.black54,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            label,
            style: const TextStyle(fontSize: 12, color: Colors.white),
          ),
        ),
        const SizedBox(height: 4),
      ],
    );
  }
}

/// Numbered cards on grey, with enough contrast between neighbors that
/// refraction and blur are easy to see.
class _Backdrop extends StatelessWidget {
  const _Backdrop();

  // White, light grey, pale blue, cream — all near-white.
  static const _cardColors = [
    Colors.white,
    Color(0xFFE3E3E3),
    Color(0xFFD9E4F5),
    Color(0xFFF6EFDE),
  ];

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xFFF2F2F2),
      child: GridView.builder(
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 110,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
        ),
        itemCount: 80,
        itemBuilder: (context, i) {
          final color = _cardColors[i % _cardColors.length];
          return DecoratedBox(
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Center(
              child: Text(
                '$i',
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: Colors.black87,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
