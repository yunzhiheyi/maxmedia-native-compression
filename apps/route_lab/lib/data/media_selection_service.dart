import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:maxmedia_video_native/maxmedia_video_native.dart';
import 'package:path_provider/path_provider.dart';

enum SelectedMediaKind { image, video }

final class SelectedMedia {
  const SelectedMedia({
    required this.inputPath,
    required this.outputPath,
    required this.displayName,
    this.accessMode,
    this.acquisitionElapsedMilliseconds,
  });

  final String inputPath;
  final String outputPath;
  final String displayName;
  final String? accessMode;
  final int? acquisitionElapsedMilliseconds;
}

abstract interface class MediaSelectionService {
  Future<SelectedMedia?> pickImage();
  Future<SelectedMedia?> pickVideo();

  /// Multi-select variants for the batch routes.
  Future<List<SelectedMedia>> pickImages();
  Future<List<SelectedMedia>> pickVideos();
}

final class NativeMediaSelectionService implements MediaSelectionService {
  const NativeMediaSelectionService();

  @override
  Future<SelectedMedia?> pickImage() => _pick(
    kind: SelectedMediaKind.image,
    type: FileType.image,
    outputExtension: 'jpg',
  );

  @override
  Future<SelectedMedia?> pickVideo() async {
    if (Platform.isIOS) {
      try {
        final source = await const MaxmediaVideoNative().pickVideoSource();
        if (source == null) return null;
        return _selectionForPath(
          kind: SelectedMediaKind.video,
          inputPath: source.path,
          displayName: source.displayName,
          outputExtension: 'mp4',
          accessMode: source.accessMode,
          acquisitionElapsedMilliseconds: source.elapsedMilliseconds,
        );
      } on MissingPluginException {
        // Older builds fall back to the general file picker below.
      } on PlatformException catch (error) {
        if (error.code != 'VIDEO_PICKER_UNAVAILABLE') rethrow;
      }
    }
    return _pick(
      kind: SelectedMediaKind.video,
      type: FileType.video,
      outputExtension: 'mp4',
    );
  }

  @override
  Future<List<SelectedMedia>> pickImages() => _pickMany(
    kind: SelectedMediaKind.image,
    type: FileType.image,
    outputExtension: 'jpg',
  );

  @override
  Future<List<SelectedMedia>> pickVideos() async {
    if (Platform.isIOS) {
      try {
        final sources = await const MaxmediaVideoNative().pickVideoSources();
        final selections = <SelectedMedia>[];
        for (final source in sources) {
          selections.add(
            await _selectionForPath(
              kind: SelectedMediaKind.video,
              inputPath: source.path,
              displayName: source.displayName,
              outputExtension: 'mp4',
              accessMode: source.accessMode,
              acquisitionElapsedMilliseconds: source.elapsedMilliseconds,
            ),
          );
        }
        return selections;
      } on MissingPluginException {
        // Unimplemented platforms fall back to the general file picker.
      } on PlatformException catch (error) {
        if (error.code != 'VIDEO_PICKER_UNAVAILABLE') rethrow;
      }
    }
    return _pickMany(
      kind: SelectedMediaKind.video,
      type: FileType.video,
      outputExtension: 'mp4',
    );
  }

  Future<List<SelectedMedia>> _pickMany({
    required SelectedMediaKind kind,
    required FileType type,
    required String outputExtension,
  }) async {
    final acquisitionStopwatch = Stopwatch()..start();
    final files = await FilePicker.pickFiles(
      type: type,
      darwinOptions: type == FileType.video
          ? const DarwinOptions(
              assetRepresentationMode: DarwinAssetRepresentationMode.current,
            )
          : const DarwinOptions(),
    );
    acquisitionStopwatch.stop();
    final acquisitions = <SelectedMedia>[];
    for (final file in files) {
      final inputPath = file.path;
      if (inputPath == null || inputPath.isEmpty) continue;
      acquisitions.add(
        await _selectionForPath(
          kind: kind,
          inputPath: inputPath,
          displayName: file.name,
          outputExtension: outputExtension,
          accessMode: 'file-picker-copy',
          acquisitionElapsedMilliseconds:
              acquisitionStopwatch.elapsedMilliseconds,
        ),
      );
    }
    return acquisitions;
  }

  Future<SelectedMedia?> _pick({
    required SelectedMediaKind kind,
    required FileType type,
    required String outputExtension,
  }) async {
    Stopwatch? acquisitionStopwatch;
    final file = await FilePicker.pickFile(
      type: type,
      darwinOptions: type == FileType.video
          ? const DarwinOptions(
              assetRepresentationMode: DarwinAssetRepresentationMode.current,
            )
          : const DarwinOptions(),
      onFileLoading: (status) {
        if (status == FilePickerStatus.picking) {
          acquisitionStopwatch ??= Stopwatch()..start();
        } else {
          acquisitionStopwatch?.stop();
        }
      },
    );
    if (file == null) return null;
    final inputPath = file.path;
    if (inputPath == null || inputPath.isEmpty) {
      throw StateError('所选文件没有可供原生压缩器读取的本地路径');
    }

    return _selectionForPath(
      kind: kind,
      inputPath: inputPath,
      displayName: file.name,
      outputExtension: outputExtension,
      accessMode: 'file-picker-copy',
      acquisitionElapsedMilliseconds: acquisitionStopwatch?.elapsedMilliseconds,
    );
  }

  Future<SelectedMedia> _selectionForPath({
    required SelectedMediaKind kind,
    required String inputPath,
    required String displayName,
    required String outputExtension,
    String? accessMode,
    int? acquisitionElapsedMilliseconds,
  }) async {
    final temporaryDirectory = await getTemporaryDirectory();
    final outputDirectory = Directory(
      '${temporaryDirectory.path}${Platform.pathSeparator}maxmedia-route-lab',
    );
    await outputDirectory.create(recursive: true);
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final outputPath =
        '${outputDirectory.path}${Platform.pathSeparator}'
        '${kind.name}-$stamp.$outputExtension';
    return SelectedMedia(
      inputPath: inputPath,
      outputPath: outputPath,
      displayName: displayName,
      accessMode: accessMode,
      acquisitionElapsedMilliseconds: acquisitionElapsedMilliseconds,
    );
  }
}
