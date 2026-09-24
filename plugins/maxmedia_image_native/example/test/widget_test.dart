import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maxmedia_image_native_example/main.dart';

void main() {
  testWidgets('shows the compression action', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: ImageExample()));
    expect(find.text('Choose image and compress'), findsOneWidget);
  });
}
