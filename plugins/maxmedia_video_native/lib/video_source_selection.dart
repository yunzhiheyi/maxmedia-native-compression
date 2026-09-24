final class VideoSourceSelection {
  const VideoSourceSelection({
    required this.path,
    required this.displayName,
    required this.accessMode,
    required this.elapsedMilliseconds,
  });

  final String path;
  final String displayName;
  final String accessMode;
  final int elapsedMilliseconds;

  factory VideoSourceSelection.fromMap(Map<Object?, Object?> value) {
    final path = value['path'];
    final displayName = value['displayName'];
    final accessMode = value['accessMode'];
    final elapsedMilliseconds = value['elapsedMilliseconds'];
    if (path is! String ||
        displayName is! String ||
        accessMode is! String ||
        elapsedMilliseconds is! num) {
      throw const FormatException('Invalid video source selection');
    }
    return VideoSourceSelection(
      path: path,
      displayName: displayName,
      accessMode: accessMode,
      elapsedMilliseconds: elapsedMilliseconds.toInt(),
    );
  }
}
