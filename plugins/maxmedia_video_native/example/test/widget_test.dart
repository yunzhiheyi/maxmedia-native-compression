import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maxmedia_video_native_example/main.dart';

void main() {
  testWidgets('shows the compression action', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: VideoExample()));
    expect(find.text('Choose video and compress'), findsOneWidget);
  });
}
