import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:maxmedia_route_lab/data/media_selection_service.dart';
import 'package:maxmedia_route_lab/data/route_repository.dart';
import 'package:maxmedia_route_lab/main.dart';
import 'package:maxmedia_route_lab/presentation/route_lab_view_model.dart';
import 'package:maxmedia_route_lab/data/compression_service.dart';
import 'package:media_route_contracts/media_route_contracts.dart';
import 'package:path_provider/path_provider.dart';

/// Drives the real Route Lab UI on a physical device: select the pushed
/// source image, run the native WebP compression through the actual buttons,
/// and verify the on-screen result summary against the real output file.
///
/// The system photo picker is the only step that cannot be automated, so the
/// injected [DocumentsSelectionService] resolves the pre-pushed file in the
/// app's Documents directory instead; every other step is the production UI.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('compress an image end to end through the real device UI', (
    tester,
  ) async {
    final documents = await getApplicationDocumentsDirectory();
    final source = File('${documents.path}/adaptive-input.jpg');
    // A fresh install creates the app container, so the source file is pushed
    // from the Mac with devicectl while this wait window is open.
    const inputWaitSeconds = int.fromEnvironment('UI_TEST_INPUT_WAIT_SECONDS');
    for (
      var second = 0;
      second < inputWaitSeconds && !await source.exists();
      second += 1
    ) {
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    expect(await source.exists(), isTrue,
        reason: 'Push adaptive-input.jpg into Documents while the test waits.');

    final output = File('${documents.path}/ui-test-output.webp');
    if (await output.exists()) await output.delete();

    final selection = DocumentsSelectionService(
      inputPath: source.path,
      outputPath: output.path,
      displayName: 'adaptive-input.jpg',
    );
    final viewModel = RouteLabViewModel(
      RouteRepository(const NativeCompressionService()),
    );
    await tester.pumpWidget(
      RouteLabApp(viewModel: viewModel, mediaSelectionService: selection),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('pick-image')));
    await tester.pumpAndSettle();

    final compressButton = tester.widget<FilledButton>(
      find.byKey(const ValueKey('compress-image')),
    );
    expect(compressButton.onPressed, isNotNull);

    await tester.tap(find.byKey(const ValueKey('compress-image')));
    await tester.pumpAndSettle(const Duration(seconds: 60));

    expect(viewModel.phase, RouteLabPhase.succeeded);
    expect(find.text('原文件与压缩结果'), findsOneWidget);

    final result = viewModel.result!;
    expect(result.terminal, CompressionTerminal.succeeded);
    expect(await output.exists(), isTrue);
    expect(await output.length(), result.outputBytes);

    final report = <String, Object?>{
      'inputBytes': result.inputBytes,
      'outputBytes': result.outputBytes,
      'compressionRatio': result.compressionRatio,
      'elapsedMilliseconds': result.elapsedMilliseconds,
      'outputPath': result.outputPath,
      'actualSettings': result.actualSettings,
      'warnings': result.warnings,
    };
    // ignore: avoid_print
    print('DEVICE_UI_RESULT_JSON=${jsonEncode(report)}');
  });
}

final class DocumentsSelectionService implements MediaSelectionService {
  DocumentsSelectionService({
    required this.inputPath,
    required this.outputPath,
    required this.displayName,
  });

  final String inputPath;
  final String outputPath;
  final String displayName;

  @override
  Future<SelectedMedia?> pickImage() async => SelectedMedia(
    inputPath: inputPath,
    outputPath: outputPath,
    displayName: displayName,
    accessMode: 'documents-direct',
  );

  @override
  Future<SelectedMedia?> pickVideo() async => null;

  @override
  Future<List<SelectedMedia>> pickImages() async => const [];

  @override
  Future<List<SelectedMedia>> pickVideos() async => const [];
}
