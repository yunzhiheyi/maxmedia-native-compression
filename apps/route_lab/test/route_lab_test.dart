import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maxmedia_route_lab/data/compression_service.dart';
import 'package:maxmedia_route_lab/data/media_selection_service.dart';
import 'package:maxmedia_route_lab/data/route_repository.dart';
import 'package:maxmedia_route_lab/main.dart';
import 'package:maxmedia_route_lab/presentation/batch_section.dart';
import 'package:maxmedia_route_lab/presentation/result_summary.dart';
import 'package:maxmedia_route_lab/presentation/route_lab_view_model.dart';
import 'package:maxmedia_video_native/maxmedia_video_native.dart';

final class FakeCompressionGateway implements CompressionGateway {
  static const capability = CapabilityReport(
    schemaVersion: 1,
    executor: 'fake',
    platform: 'test',
    features: {'quality'},
    codecs: {'h264'},
    formats: {'jpeg', 'png', 'webp', 'heic', 'mp4'},
  );
  ImageCompressionRequest? lastImageRequest;
  VideoCompressionRequest? lastVideoRequest;

  @override
  Future<void> cancelVideo() async {}

  @override
  Future<void> cancelImages() async {}

  @override
  Future<CapabilityReport> imageCapabilities() async => capability;

  @override
  Future<CapabilityReport> videoCapabilities() async => capability;

  @override
  Future<CompressionResult> compressImage(
    ImageCompressionRequest request,
  ) async {
    lastImageRequest = request;
    return _result(request.outputPath, {'format': request.format.name});
  }

  @override
  Future<CompressionResult> compressVideo(
    VideoCompressionRequest request,
  ) async {
    lastVideoRequest = request;
    return _result(request.outputPath, {'codec': request.codec.name});
  }

  CompressionResult _result(String path, Map<String, Object?> settings) =>
      CompressionResult(
        schemaVersion: 1,
        terminal: CompressionTerminal.succeeded,
        executor: 'fake',
        outputPath: path,
        elapsedMilliseconds: 1,
        inputBytes: 10,
        outputBytes: 5,
        actualSettings: settings,
      );

  @override
  Stream<VideoCompressionProgress> get videoProgress => const Stream.empty();
}

final class FakeMediaSelectionService implements MediaSelectionService {
  @override
  Future<SelectedMedia?> pickImage() async => const SelectedMedia(
    inputPath: '/picked.png',
    outputPath: '/output.jpg',
    displayName: 'picked.png',
  );

  @override
  Future<SelectedMedia?> pickVideo() async => const SelectedMedia(
    inputPath: '/picked.mp4',
    outputPath: '/output.mp4',
    displayName: 'picked.mp4',
    accessMode: 'provider-copy',
    acquisitionElapsedMilliseconds: 50,
  );

  @override
  Future<List<SelectedMedia>> pickImages() async => const [];

  @override
  Future<List<SelectedMedia>> pickVideos() async => const [];
}

final class ControllableVideoGateway implements CompressionGateway {
  final progressController = StreamController<VideoCompressionProgress>();
  final resultCompleter = Completer<CompressionResult>();

  @override
  Stream<VideoCompressionProgress> get videoProgress =>
      progressController.stream;

  @override
  Future<void> cancelVideo() async {}

  @override
  Future<void> cancelImages() async {}

  @override
  Future<CompressionResult> compressVideo(VideoCompressionRequest request) =>
      resultCompleter.future;

  @override
  Future<CompressionResult> compressImage(
    ImageCompressionRequest request,
  ) async => throw UnimplementedError();

  @override
  Future<CapabilityReport> imageCapabilities() async =>
      FakeCompressionGateway.capability;

  @override
  Future<CapabilityReport> videoCapabilities() async =>
      FakeCompressionGateway.capability;
}

final class AdaptiveImageGateway implements CompressionGateway {
  final requests = <ImageCompressionRequest>[];

  @override
  Future<CompressionResult> compressImage(
    ImageCompressionRequest request,
  ) async {
    requests.add(request);
    return CompressionResult(
      schemaVersion: 1,
      terminal: CompressionTerminal.succeeded,
      executor: 'fake-image',
      outputPath: request.outputPath,
      elapsedMilliseconds: 20,
      inputBytes: 100,
      outputBytes: 65,
      actualSettings: {
        'format': 'jpeg',
        'quality': 0.60,
        'qualityRequested': request.quality,
        'qualityApplied': 0.60,
        'adaptiveAttempts': 2,
        'targetCompressionRatio': request.targetCompressionRatio,
        'minimumUsefulQuality': request.minimumQuality,
      },
      warnings: const [
        'Image quality was adapted once to avoid repeated full-image encodes',
      ],
    );
  }

  @override
  Future<CompressionResult> compressVideo(
    VideoCompressionRequest request,
  ) async => throw UnimplementedError();

  @override
  Future<void> cancelVideo() async {}

  @override
  Future<void> cancelImages() async {}

  @override
  Future<CapabilityReport> imageCapabilities() async =>
      FakeCompressionGateway.capability;

  @override
  Future<CapabilityReport> videoCapabilities() async =>
      FakeCompressionGateway.capability;

  @override
  Stream<VideoCompressionProgress> get videoProgress => const Stream.empty();
}

void main() {
  test('view model retains the latest successful result', () async {
    final viewModel = RouteLabViewModel(
      RouteRepository(FakeCompressionGateway()),
    );
    await viewModel.compressImage(
      ImageCompressionRequest(
        inputPath: '/in.png',
        outputPath: '/out.jpg',
        format: ImageFormat.jpeg,
        quality: 0.8,
      ),
    );
    expect(viewModel.phase, RouteLabPhase.succeeded);
    expect(viewModel.result?.outputPath, '/out.jpg');
  });

  test(
    'repository adapts JPEG quality at most once without crossing the floor',
    () async {
      final gateway = AdaptiveImageGateway();
      final repository = RouteRepository(gateway);

      final result = await repository.compressImage(
        ImageCompressionRequest(
          inputPath: '/in.jpg',
          outputPath: '/out.jpg',
          format: ImageFormat.jpeg,
          quality: 0.82,
        ),
      );

      expect(gateway.requests, hasLength(1));
      expect(gateway.requests.single.quality, 0.82);
      expect(gateway.requests.single.targetCompressionRatio, 0.70);
      expect(gateway.requests.single.minimumQuality, 0.60);
      expect(result.outputBytes, 65);
      expect(result.elapsedMilliseconds, 20);
      expect(result.actualSettings['qualityRequested'], 0.82);
      expect(result.actualSettings['qualityApplied'], 0.60);
      expect(result.actualSettings['adaptiveAttempts'], 2);
      expect(result.actualSettings['minimumUsefulQuality'], 0.60);
      expect(result.warnings, isNotEmpty);
    },
  );

  testWidgets('renders both route sections', (tester) async {
    final viewModel = RouteLabViewModel(
      RouteRepository(FakeCompressionGateway()),
    );
    await tester.pumpWidget(RouteLabApp(viewModel: viewModel));
    await tester.pumpAndSettle();
    expect(find.text('图片原生路线'), findsOneWidget);
    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(find.text('视频原生路线'), findsOneWidget);
  });

  testWidgets('selecting an image fills paths and enables compression', (
    tester,
  ) async {
    final gateway = FakeCompressionGateway();
    final viewModel = RouteLabViewModel(RouteRepository(gateway));
    await tester.pumpWidget(
      RouteLabApp(
        viewModel: viewModel,
        mediaSelectionService: FakeMediaSelectionService(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('pick-image')));
    await tester.pumpAndSettle();

    expect(find.text('picked.png'), findsOneWidget);
    final button = tester.widget<FilledButton>(
      find.byKey(const ValueKey('compress-image')),
    );
    expect(button.onPressed, isNotNull);

    await tester.tap(find.byKey(const ValueKey('compress-image')));
    await tester.pumpAndSettle();
    expect(gateway.lastImageRequest?.format, ImageFormat.webp);
    expect(gateway.lastImageRequest?.quality, 0.80);
    expect(gateway.lastImageRequest?.maxWidth, isNull);
    expect(gateway.lastImageRequest?.maxHeight, isNull);
    expect(gateway.lastImageRequest?.resizePolicy, ImageResizePolicy.social);
    expect(gateway.lastImageRequest?.outputPath, '/output.webp');
  });

  testWidgets('original-size mode is explicit and reaches the plugin request', (
    tester,
  ) async {
    final gateway = FakeCompressionGateway();
    final viewModel = RouteLabViewModel(RouteRepository(gateway));
    await tester.pumpWidget(
      RouteLabApp(
        viewModel: viewModel,
        mediaSelectionService: FakeMediaSelectionService(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('pick-image')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('image-resize-policy')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保持原尺寸（高清档）').last);
    await tester.pumpAndSettle();

    expect(find.text('执行原尺寸压缩'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('compress-image')));
    await tester.pumpAndSettle();
    expect(gateway.lastImageRequest?.resizePolicy, ImageResizePolicy.original);
  });

  testWidgets('selecting a video displays source preparation evidence', (
    tester,
  ) async {
    final viewModel = RouteLabViewModel(
      RouteRepository(FakeCompressionGateway()),
    );
    await tester.pumpWidget(
      RouteLabApp(
        viewModel: viewModel,
        mediaSelectionService: FakeMediaSelectionService(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('pick-video')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('pick-video')));
    await tester.pumpAndSettle();

    expect(find.text('picked.mp4'), findsOneWidget);
    expect(find.text('视频准备：系统当前格式快速准备 · 0.05 s'), findsOneWidget);
    expect(find.text('HDR 输入策略'), findsOneWidget);
    expect(find.text('保留 HDR 原片（默认）'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('video-hdr-policy')));
    await tester.pumpAndSettle();
    expect(find.text('转换为 SDR BT.709 后转 H.264'), findsOneWidget);
    final button = tester.widget<FilledButton>(
      find.byKey(const ValueKey('compress-video')),
    );
    expect(button.onPressed, isNotNull);
  });

  testWidgets('smaller video budget reaches the native request', (
    tester,
  ) async {
    final gateway = FakeCompressionGateway();
    final viewModel = RouteLabViewModel(RouteRepository(gateway));
    await tester.pumpWidget(
      RouteLabApp(
        viewModel: viewModel,
        mediaSelectionService: FakeMediaSelectionService(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('pick-video')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(find.byKey(const ValueKey('pick-video')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('pick-video')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey('video-bitrate-budget')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('video-bitrate-budget')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('小体积 · 75% 码率').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('compress-video')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('compress-video')));
    await tester.pumpAndSettle();

    expect(gateway.lastVideoRequest?.averageBitrate, 1500000);
    expect(gateway.lastVideoRequest?.maxShortSide, 720);
    expect(gateway.lastVideoRequest?.removeAudio, isTrue);
  });

  testWidgets('batch video offers explicit HDR handling before processing', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: BatchSection(
              mediaSelectionService: FakeMediaSelectionService(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final selector = find.byKey(const ValueKey('batch-video-hdr-policy'));
    await tester.ensureVisible(selector);
    await tester.pumpAndSettle();
    expect(find.text('批量视频 HDR 处理'), findsOneWidget);
    await tester.tap(selector);
    await tester.pumpAndSettle();
    await tester.tap(find.text('转换为 SDR BT.709 后转 H.264').last);
    await tester.pumpAndSettle();
    expect(find.text('转换为 SDR BT.709 后转 H.264'), findsOneWidget);
  });

  test('view model exposes native video progress', () async {
    final gateway = ControllableVideoGateway();
    final viewModel = RouteLabViewModel(RouteRepository(gateway));
    final operation = viewModel.compressVideo(
      VideoCompressionRequest(
        inputPath: '/in.mp4',
        outputPath: '/out.mp4',
        codec: VideoCodec.h264,
        container: ContainerFormat.mp4,
        averageBitrate: 2_000_000,
      ),
    );
    await Future<void>.delayed(Duration.zero);

    gateway.progressController.add(
      const VideoCompressionProgress(fraction: 0.42, stage: 'encoding'),
    );
    await Future<void>.delayed(Duration.zero);
    expect(viewModel.progress, 0.42);
    expect(viewModel.progressLabel, '正在编码视频 42%');

    gateway.resultCompleter.complete(
      CompressionResult(
        schemaVersion: 1,
        terminal: CompressionTerminal.succeeded,
        executor: 'fake',
        outputPath: '/out.mp4',
        elapsedMilliseconds: 10,
        inputBytes: 10,
        outputBytes: 8,
        actualSettings: const {'codec': 'h264'},
      ),
    );
    await operation;
    expect(viewModel.progress, 1);
    viewModel.dispose();
    await gateway.progressController.close();
  });

  testWidgets('video compression displays progress in the action button', (
    tester,
  ) async {
    final gateway = ControllableVideoGateway();
    final viewModel = RouteLabViewModel(RouteRepository(gateway));
    await tester.pumpWidget(RouteLabApp(viewModel: viewModel));
    await tester.pumpAndSettle();

    unawaited(
      viewModel.compressVideo(
        VideoCompressionRequest(
          inputPath: '/in.mp4',
          outputPath: '/out.mp4',
          codec: VideoCodec.h264,
          container: ContainerFormat.mp4,
          averageBitrate: 2_000_000,
        ),
      ),
    );
    gateway.progressController.add(
      const VideoCompressionProgress(fraction: 0.42, stage: 'encoding'),
    );
    await tester.pump();

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('compress-video')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
    expect(find.text('压缩中 42%'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('compression-progress-panel')),
      findsNothing,
    );
  });

  testWidgets('result summary compares original and compressed image', (
    tester,
  ) async {
    final result = CompressionResult(
      schemaVersion: 1,
      terminal: CompressionTerminal.succeeded,
      executor: 'fake',
      outputPath: '/missing-output.jpg',
      elapsedMilliseconds: 1853,
      inputBytes: 6989696,
      outputBytes: 5080902,
      actualSettings: const {
        'format': 'jpeg',
        'inputWidth': 1920,
        'inputHeight': 1080,
        'width': 1280,
        'height': 720,
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ResultSummary(
              result: result,
              kind: MediaResultKind.image,
              inputPath: '/missing-input.png',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('原文件与压缩结果'), findsOneWidget);
    expect(find.text('6.67 MiB'), findsOneWidget);
    expect(find.text('4.85 MiB'), findsOneWidget);
    expect(find.text('1920×1080'), findsOneWidget);
    expect(find.text('1280×720'), findsOneWidget);
    expect(find.textContaining('耗时 1.85 s'), findsOneWidget);
  });

  testWidgets('larger output is not presented as successful compression', (
    tester,
  ) async {
    final result = CompressionResult(
      schemaVersion: 1,
      terminal: CompressionTerminal.succeeded,
      executor: 'fake',
      outputPath: '/missing-output.jpg',
      elapsedMilliseconds: 100,
      inputBytes: 10,
      outputBytes: 20,
      actualSettings: const {'format': 'jpeg'},
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ResultSummary(
              result: result,
              kind: MediaResultKind.image,
              inputPath: '/missing-input.jpg',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('未达到压缩目标'), findsOneWidget);
    expect(find.text('压缩完成'), findsNothing);
    expect(find.textContaining('输出文件不应替换原文件'), findsOneWidget);
  });

  testWidgets('video result shows call timings and HDR validation warning', (
    tester,
  ) async {
    final result = CompressionResult(
      schemaVersion: 1,
      terminal: CompressionTerminal.succeeded,
      executor: 'fake',
      outputPath: '/missing-output.mp4',
      elapsedMilliseconds: 23000,
      inputBytes: 100,
      outputBytes: 50,
      actualSettings: const {
        'codec': 'h264',
        'performance': {
          'readerCallMilliseconds': 8000.0,
          'writerBackpressureMilliseconds': 12000.0,
          'writerAppendMilliseconds': 1000.0,
          'finishWritingMilliseconds': 500.0,
        },
      },
      warnings: const [
        'HDR source was decoded to 8-bit and encoded as H.264; HDR preservation and SDR tone mapping are not validated',
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ResultSummary(
              result: result,
              kind: MediaResultKind.video,
              inputPath: '/missing-input.mov',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('性能诊断'), findsOneWidget);
    expect(find.textContaining('取帧调用 8.00 s'), findsOneWidget);
    expect(find.textContaining('HDR 已按 8-bit 转码'), findsOneWidget);
  });

  testWidgets('video result reveals HDR to SDR color change', (tester) async {
    final result = CompressionResult(
      schemaVersion: 1,
      terminal: CompressionTerminal.succeeded,
      executor: 'apple',
      outputPath: '/missing-output.mp4',
      elapsedMilliseconds: 2450,
      inputBytes: 100,
      outputBytes: 20,
      actualSettings: const {
        'hdrHandling': 'tone-map-to-sdr',
        'input': {
          'colorPrimaries': 'ITU_R_2020',
          'transferFunction': 'ITU_R_2100_HLG',
        },
        'output': {
          'colorPrimaries': 'ITU_R_709_2',
          'transferFunction': 'ITU_R_709_2',
        },
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ResultSummary(
              result: result,
              kind: MediaResultKind.video,
              inputPath: '/missing-input.mov',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('HDR 处理：已转换为 SDR BT.709 后再编码 H.264。'), findsOneWidget);
    expect(find.text('BT.2020'), findsOneWidget);
    expect(find.text('HLG'), findsOneWidget);
    expect(find.text('BT.709'), findsNWidgets(2));
  });
}
