import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:just_liquid_glass/just_liquid_glass.dart';
import 'package:just_liquid_glass_example/showcase_main.dart';

void main() {
  testWidgets('showcase grid renders a GlassLayer per cell', (tester) async {
    // The showcase's four square rows only fit a portrait surface; the
    // default 800x600 test view overflows by construction.
    tester.view.physicalSize = const Size(1800, 3000);
    addTearDown(tester.view.reset);

    await tester.runAsync(GlassLayer.precache);

    await tester.pumpWidget(const ShowcaseApp());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(GlassLayer), findsNWidgets(12));
    expect(tester.takeException(), isNull);
  });
}
