import 'package:flutter_test/flutter_test.dart';
import 'package:just_liquid_glass/just_liquid_glass.dart';
import 'package:just_liquid_glass_example/main.dart';

void main() {
  testWidgets(
      'shaders load through the packages/ asset prefix and the demo renders',
      (tester) async {
    // In a consuming app the shader assets must resolve under
    // packages/just_liquid_glass/; this is the path production apps hit.
    await tester.runAsync(GlassLayer.precache);

    await tester.pumpWidget(const DemoApp());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(GlassLayer), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
