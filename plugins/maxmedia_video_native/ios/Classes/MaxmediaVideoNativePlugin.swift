import AVFoundation
import Flutter
import Photos
import PhotosUI
import UniformTypeIdentifiers
import UIKit

public class MaxmediaVideoNativePlugin: NSObject, FlutterPlugin, FlutterStreamHandler,
  PHPickerViewControllerDelegate {
  private let stateLock = NSLock()
  private var currentReader: AVAssetReader?
  private var currentWriter: AVAssetWriter?
  private var busy = false
  private var cancelled = false
  private var progressSink: FlutterEventSink?
  private weak var viewController: UIViewController?
  private var pendingPickerResult: FlutterResult?
  private var pendingPickerExpectsList = false
  // PhotoKit URLs can die once the picker releases the asset; retaining by
  // path keeps every batch item readable until its own compression runs.
  private var retainedPhotoAssets: [String: AVAsset] = [:]

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "maxmedia_video_native",
      binaryMessenger: registrar.messenger()
    )
    let instance = MaxmediaVideoNativePlugin()
    instance.viewController = registrar.viewController
    registrar.addMethodCallDelegate(instance, channel: channel)
    let progressChannel = FlutterEventChannel(
      name: "maxmedia_video_native/progress",
      binaryMessenger: registrar.messenger()
    )
    progressChannel.setStreamHandler(instance)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "capabilities":
      result(capabilities())
    case "pickVideoSource":
      DispatchQueue.main.async { self.presentVideoPicker(limit: 1, result: result) }
    case "pickVideoSources":
      DispatchQueue.main.async { self.presentVideoPicker(limit: 0, result: result) }
    case "cancel":
      cancel()
      result(nil)
    case "compress":
      guard let arguments = call.arguments as? [String: Any] else {
        result(FlutterError(code: "INVALID_ARGUMENT", message: "Expected request map", details: nil))
        return
      }
      guard beginTask() else {
        result(FlutterError(code: "BUSY", message: "A video export is already running", details: nil))
        return
      }
      DispatchQueue.global(qos: .userInitiated).async {
        defer { self.finishTask() }
        do {
          let value = try self.compress(arguments)
          DispatchQueue.main.async { result(value) }
        } catch {
          DispatchQueue.main.async {
            result(FlutterError(
              code: (error as? PluginError)?.code ?? "VIDEO_COMPRESSION_FAILED",
              message: error.localizedDescription,
              details: nil
            ))
          }
        }
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func capabilities() -> [String: Any] {
    [
      "schemaVersion": 1,
      "executor": "apple-avassetreader-writer-v0",
      "platform": "ios",
      "features": [
        "average-bitrate", "gop", "cancel", "progress", "video-only",
        "downscale-short-side",
        "photo-picker-current-representation", "fast-source-persistence"
      ],
      "codecs": ["h264", "hevc"],
      "formats": ["mp4", "mov"],
      "warnings": [
        "V0 requires removeAudio=true",
        "V0 downscales via maxShortSide only; explicit width/height and frame rate changes are rejected",
        "HDR sources are kept unchanged by default because color-preserving transcoding is not validated"
      ]
    ]
  }

  private func presentVideoPicker(limit: Int, result: @escaping FlutterResult) {
    guard pendingPickerResult == nil else {
      result(
        FlutterError(
          code: "VIDEO_PICKER_BUSY",
          message: "A video picker request is already active",
          details: nil
        )
      )
      return
    }
    guard let viewController else {
      result(
        FlutterError(
          code: "VIDEO_PICKER_UNAVAILABLE",
          message: "No Flutter view controller is available",
          details: nil
        )
      )
      return
    }

    pendingPickerResult = result
    pendingPickerExpectsList = limit == 0
    var configuration = PHPickerConfiguration(photoLibrary: .shared())
    configuration.filter = .videos
    configuration.selectionLimit = limit
    configuration.preferredAssetRepresentationMode = .current
    let picker = PHPickerViewController(configuration: configuration)
    picker.delegate = self
    viewController.present(picker, animated: true)
  }

  public func picker(
    _ picker: PHPickerViewController,
    didFinishPicking results: [PHPickerResult]
  ) {
    picker.dismiss(animated: true)
    if pendingPickerExpectsList {
      resolveMultipleVideos(results)
      return
    }
    guard let selection = results.first else {
      finishVideoPicker(nil)
      return
    }

    let started = DispatchTime.now()
    if let identifier = selection.assetIdentifier,
       photoLibraryCanReadAssets(),
       let photoAsset = PHAsset.fetchAssets(
         withLocalIdentifiers: [identifier],
         options: nil
       ).firstObject {
      resolveOneVideo(selection, started: started, completion: finishVideoPicker)
      return
    }

    resolveOneVideo(selection, started: started, completion: finishVideoPicker)
  }

  private func resolveOneVideo(
    _ selection: PHPickerResult,
    started: DispatchTime,
    completion: @escaping (Any?) -> Void
  ) {
    if let identifier = selection.assetIdentifier,
       photoLibraryCanReadAssets(),
       let photoAsset = PHAsset.fetchAssets(
         withLocalIdentifiers: [identifier],
         options: nil
       ).firstObject {
      let options = PHVideoRequestOptions()
      options.deliveryMode = .highQualityFormat
      options.version = .current
      options.isNetworkAccessAllowed = true
      PHImageManager.default().requestAVAsset(
        forVideo: photoAsset,
        options: options
      ) { [weak self] asset, _, _ in
        guard let self else { return }
        if let asset,
           let urlAsset = asset as? AVURLAsset,
           urlAsset.url.isFileURL,
           FileManager.default.isReadableFile(atPath: urlAsset.url.path) {
          let name = PHAssetResource.assetResources(for: photoAsset)
            .first?.originalFilename ?? urlAsset.url.lastPathComponent
          self.retainPhotoAsset(asset, path: urlAsset.url.path)
          completion(
            self.videoSelectionValue(
              path: urlAsset.url.path,
              displayName: name,
              accessMode: "photo-library-direct",
              started: started
            )
          )
          return
        }
        self.resolveProviderVideo(selection.itemProvider, started: started, completion: completion)
      }
      return
    }

    resolveProviderVideo(selection.itemProvider, started: started, completion: completion)
  }

  /// Resolves every picked asset independently and answers once with the
  /// successful selections in input order; a failed item is skipped rather
  /// than failing the whole multi-pick.
  private func resolveMultipleVideos(_ results: [PHPickerResult]) {
    guard !results.isEmpty else {
      finishVideoPicker(["sources": [Any]()])
      return
    }
    let started = DispatchTime.now()
    let group = DispatchGroup()
    let lock = NSLock()
    var values = [Any?](repeating: nil, count: results.count)
    for (index, selection) in results.enumerated() {
      group.enter()
      resolveOneVideo(selection, started: started) { payload in
        lock.lock()
        values[index] = payload as? [String: Any]
        lock.unlock()
        group.leave()
      }
    }
    group.notify(queue: .main) { [weak self] in
      let sources = values.compactMap { $0 }
      self?.finishVideoPicker(["sources": sources])
    }
  }

  private func photoLibraryCanReadAssets() -> Bool {
    let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    return status == .authorized || status == .limited
  }

  private func resolveProviderVideo(
    _ provider: NSItemProvider,
    started: DispatchTime,
    completion: @escaping (Any?) -> Void
  ) {
    let identifier = provider.registeredTypeIdentifiers.first {
      UTType($0)?.conforms(to: .movie) == true
    } ?? UTType.movie.identifier
    provider.loadFileRepresentation(forTypeIdentifier: identifier) {
      [weak self] sourceURL, error in
      guard let self else { return }
      guard let sourceURL else {
        completion(
          FlutterError(
            code: "VIDEO_SOURCE_UNAVAILABLE",
            message: error?.localizedDescription ?? "The selected video has no local representation",
            details: nil
          )
        )
        return
      }

      do {
        let stable = try self.persistProviderVideo(
          sourceURL,
          suggestedName: provider.suggestedName
        )
        completion(
          self.videoSelectionValue(
            path: stable.url.path,
            displayName: stable.displayName,
            accessMode: stable.accessMode,
            started: started
          )
        )
      } catch {
        completion(
          FlutterError(
            code: "VIDEO_SOURCE_COPY_FAILED",
            message: error.localizedDescription,
            details: nil
          )
        )
      }
    }
  }

  private func persistProviderVideo(
    _ sourceURL: URL,
    suggestedName: String?
  ) throws -> (url: URL, displayName: String, accessMode: String) {
    let directory = FileManager.default.urls(
      for: .cachesDirectory,
      in: .userDomainMask
    )[0].appendingPathComponent("maxmedia-native-picker", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    // Other selected items, including items in a running queue, may still
    // read files from this directory. Never clear it while resolving a pick.
    let fallbackExtension = sourceURL.pathExtension.isEmpty
      ? "mov" : sourceURL.pathExtension
    let proposedName = URL(fileURLWithPath: suggestedName ?? sourceURL.lastPathComponent)
      .lastPathComponent
    let displayName = proposedName.isEmpty
      ? "video.\(fallbackExtension)" : proposedName
    let destination = directory.appendingPathComponent(
      "\(DispatchTime.now().uptimeNanoseconds)-\(displayName)"
    )

    do {
      try FileManager.default.linkItem(at: sourceURL, to: destination)
      return (destination, displayName, "provider-hardlink")
    } catch {
      try FileManager.default.copyItem(at: sourceURL, to: destination)
      return (destination, displayName, "provider-copy")
    }
  }

  private func videoSelectionValue(
    path: String,
    displayName: String,
    accessMode: String,
    started: DispatchTime
  ) -> [String: Any] {
    let elapsed = DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds
    return [
      "path": path,
      "displayName": displayName,
      "accessMode": accessMode,
      "elapsedMilliseconds": Int(elapsed / 1_000_000)
    ]
  }

  private func finishVideoPicker(_ value: Any?) {
    DispatchQueue.main.async {
      let result = self.pendingPickerResult
      self.pendingPickerResult = nil
      self.pendingPickerExpectsList = false
      result?(value)
    }
  }

  private func retainPhotoAsset(_ asset: AVAsset, path: String) {
    stateLock.lock()
    retainedPhotoAssets[path] = asset
    stateLock.unlock()
  }

  private func assetForInput(_ path: String) -> AVAsset? {
    stateLock.lock()
    defer { stateLock.unlock() }
    return retainedPhotoAssets[path]
  }

  private func compress(_ arguments: [String: Any]) throws -> [String: Any] {
    guard (arguments["schemaVersion"] as? Int) == 1,
          let inputPath = arguments["inputPath"] as? String,
          let outputPath = arguments["outputPath"] as? String,
          let codecName = arguments["codec"] as? String,
          let containerName = arguments["container"] as? String,
          let averageBitrate = arguments["averageBitrate"] as? Int else {
      throw PluginError.invalidRequest
    }
    let hdrPolicy = arguments["hdrPolicy"] as? String ?? "keepOriginal"
    guard hdrPolicy == "keepOriginal"
      || hdrPolicy == "allowWithWarning"
      || hdrPolicy == "toneMapToSdr"
      || hdrPolicy == "rejectH264" else {
      throw PluginError.invalidRequest
    }
    guard arguments["removeAudio"] as? Bool == true else {
      throw PluginError.unsupported("V0 requires removeAudio=true")
    }
    let requestStarted = DispatchTime.now().uptimeNanoseconds
    emitProgress(0, stage: "probing")

    let inputURL = URL(fileURLWithPath: inputPath)
    let outputURL = URL(fileURLWithPath: outputPath)
    try validateDistinctPaths(inputURL, outputURL)
    var outputPrepared = false
    var outputAccepted = false
    defer {
      if outputPrepared && !outputAccepted {
        try? FileManager.default.removeItem(at: outputURL)
      }
    }
    let asset = assetForInput(inputPath) ?? AVURLAsset(url: inputURL)
    guard let videoTrack = asset.tracks(withMediaType: .video).first else {
      throw PluginError.noVideoTrack
    }
    let sourceIsHDR = isHDRTrack(videoTrack)
    if sourceIsHDR && hdrPolicy == "keepOriginal" {
      throw PluginError.hdrProtected
    }

    let sourceGeometry = videoGeometry(videoTrack)
    let targetGeometry = scaledGeometry(
      sourceGeometry,
      maxShortSide: arguments["maxShortSide"] as? Int
    )
    let scaling = targetGeometry.encodedWidth != sourceGeometry.encodedWidth
      || targetGeometry.encodedHeight != sourceGeometry.encodedHeight
    let inputDurationMilliseconds = Int(max(0, CMTimeGetSeconds(asset.duration)) * 1000)
    let sourceBitrate = max(0, Int(videoTrack.estimatedDataRate.rounded()))
    let passthrough = !scaling
      && trackCodecName(videoTrack) == codecName
      && !asset.tracks(withMediaType: .audio).isEmpty
      && sourceBitrate > 0
      && sourceBitrate <= averageBitrate
      && !(sourceIsHDR && codecName == "h264" && hdrPolicy != "allowWithWarning")
    if sourceIsHDR && !passthrough && codecName == "h264" && hdrPolicy == "rejectH264" {
      throw PluginError.unsupported(
        "HDR source cannot use the 8-bit H.264 route when hdrPolicy=rejectH264; HEVC color preservation is also unverified"
      )
    }
    if sourceIsHDR && !passthrough && codecName == "hevc" && hdrPolicy == "toneMapToSdr" {
      throw PluginError.unsupported("HDR-to-SDR tone mapping is only implemented for H.264 output")
    }
    let appliedBitrate = passthrough
      ? sourceBitrate
      : adaptiveBitrate(
          requested: averageBitrate,
          inputPath: inputPath,
          estimatedDataRate: Double(videoTrack.estimatedDataRate),
          durationMilliseconds: inputDurationMilliseconds
        )
    if let width = arguments["width"] as? Int,
       let height = arguments["height"] as? Int,
       (width != sourceGeometry.displayWidth || height != sourceGeometry.displayHeight) {
      throw PluginError.unsupported(
        "Explicit width/height is not supported; use maxShortSide"
      )
    }
    if let maxFrameRate = arguments["maxFrameRate"] as? Double,
       videoTrack.nominalFrameRate > 0,
       maxFrameRate + 0.01 < Double(videoTrack.nominalFrameRate) {
      throw PluginError.unsupported("V0 does not drop frames")
    }

    try FileManager.default.createDirectory(
      at: outputURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try? FileManager.default.removeItem(at: outputURL)
    outputPrepared = true

    let reader = try AVAssetReader(asset: asset)
    let toneMapToSdr = sourceIsHDR
      && !passthrough
      && codecName == "h264"
      && hdrPolicy == "toneMapToSdr"
    let readerOutput: AVAssetReaderOutput
    if toneMapToSdr {
      let compositionOutput = AVAssetReaderVideoCompositionOutput(
        videoTracks: [videoTrack],
        videoSettings: [
          kCVPixelBufferPixelFormatTypeKey as String:
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
          AVVideoColorPropertiesKey: sdrColorProperties()
        ]
      )
      compositionOutput.videoComposition = sdrVideoComposition(
        asset: asset,
        track: videoTrack,
        geometry: sourceGeometry
      )
      readerOutput = compositionOutput
    } else {
      readerOutput = AVAssetReaderTrackOutput(
        track: videoTrack,
        outputSettings: passthrough ? nil : [
          kCVPixelBufferPixelFormatTypeKey as String:
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
      )
    }
    readerOutput.alwaysCopiesSampleData = false
    guard reader.canAdd(readerOutput) else { throw PluginError.readerConfiguration }
    reader.add(readerOutput)

    let fileType: AVFileType = containerName == "mov" ? .mov : .mp4
    let writer = try AVAssetWriter(outputURL: outputURL, fileType: fileType)
    let codec: AVVideoCodecType
    switch codecName {
    case "h264": codec = .h264
    case "hevc": codec = .hevc
    default: throw PluginError.unsupported("Unsupported codec: \(codecName)")
    }

    let writerInput: AVAssetWriterInput
    if passthrough {
      let sourceFormatHint = videoTrack.formatDescriptions.first.map {
        $0 as! CMFormatDescription
      }
      writerInput = AVAssetWriterInput(
        mediaType: .video,
        outputSettings: nil,
        sourceFormatHint: sourceFormatHint
      )
    } else {
      var compression: [String: Any] = [
        AVVideoAverageBitRateKey: appliedBitrate,
        AVVideoMaxKeyFrameIntervalDurationKey:
          (arguments["gopSeconds"] as? Double) ?? 2.0
      ]
      if videoTrack.nominalFrameRate > 0 {
        compression[AVVideoExpectedSourceFrameRateKey] = Int(videoTrack.nominalFrameRate.rounded())
      }
      if codec == .h264 {
        compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
      }
      var settings: [String: Any] = [
        AVVideoCodecKey: codec,
        // AVAssetReader yields pixels in the track's encoded orientation. The
        // preferred transform is written separately below, so using display
        // dimensions here would rotate portrait sources twice.
        AVVideoWidthKey: targetGeometry.encodedWidth,
        AVVideoHeightKey: targetGeometry.encodedHeight,
        // Rounding each edge to an even number can leave the target a fraction
        // of a percent off the source ratio; AspectFill absorbs that as a
        // sub-pixel crop instead of letterboxing the frame.
        AVVideoScalingModeKey: AVVideoScalingModeResizeAspectFill,
        AVVideoCompressionPropertiesKey: compression
      ]
      if toneMapToSdr {
        settings[AVVideoColorPropertiesKey] = sdrColorProperties()
      }
      guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
        throw PluginError.writerConfiguration
      }
      writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    }
    writerInput.expectsMediaDataInRealTime = false
    writerInput.transform = videoTrack.preferredTransform
    guard writer.canAdd(writerInput) else { throw PluginError.writerConfiguration }
    writer.add(writerInput)

    stateLock.lock()
    currentReader = reader
    currentWriter = writer
    stateLock.unlock()

    let started = DispatchTime.now()
    var metrics = VideoPipelineMetrics()
    metrics.setupNanoseconds = started.uptimeNanoseconds - requestStarted
    func cancelledResult() -> [String: Any] {
      if reader.status == .reading { reader.cancelReading() }
      if writer.status == .writing { writer.cancelWriting() }
      try? FileManager.default.removeItem(at: outputURL)
      emitProgress(0, stage: "cancelled")
      clearCurrent()
      return terminalResult(
        terminal: "cancelled",
        inputPath: inputPath,
        outputPath: outputPath,
        codec: codecName,
        requestedBitrate: averageBitrate,
        appliedBitrate: appliedBitrate,
        width: targetGeometry.displayWidth,
        height: targetGeometry.displayHeight,
        passthrough: passthrough,
        started: started,
        sourceIsHDR: sourceIsHDR,
        hdrPolicy: hdrPolicy,
        toneMapToSdr: toneMapToSdr,
        metrics: metrics
      )
    }
    let durationSeconds = CMTimeGetSeconds(asset.duration)
    var lastProgressAt = started.uptimeNanoseconds
    var lastProgressFraction = 0.0
    emitProgress(0, stage: "encoding")
    if isCancelled() { return cancelledResult() }
    let startWritingAt = DispatchTime.now().uptimeNanoseconds
    guard writer.startWriting(), reader.startReading() else {
      if isCancelled() { return cancelledResult() }
      clearCurrent()
      throw PluginError.startFailed(reader.error ?? writer.error)
    }
    writer.startSession(atSourceTime: .zero)
    metrics.startWritingNanoseconds = DispatchTime.now().uptimeNanoseconds - startWritingAt
    let loopStarted = DispatchTime.now().uptimeNanoseconds

    while reader.status == .reading {
      if isCancelled() { return cancelledResult() }
      if writerInput.isReadyForMoreMediaData {
        let readStarted = DispatchTime.now().uptimeNanoseconds
        let nextSample = readerOutput.copyNextSampleBuffer()
        metrics.readerCallNanoseconds += DispatchTime.now().uptimeNanoseconds - readStarted
        guard let sample = nextSample else { break }
        metrics.sampleCount += 1
        let appendStarted = DispatchTime.now().uptimeNanoseconds
        let appended = writerInput.append(sample)
        metrics.writerAppendNanoseconds += DispatchTime.now().uptimeNanoseconds - appendStarted
        if !appended {
          reader.cancelReading()
          writer.cancelWriting()
          clearCurrent()
          throw PluginError.appendFailed(writer.error)
        }
        let presentationSeconds = CMTimeGetSeconds(
          CMSampleBufferGetPresentationTimeStamp(sample)
        )
        let now = DispatchTime.now().uptimeNanoseconds
        if durationSeconds.isFinite, durationSeconds > 0, presentationSeconds.isFinite {
          let fraction = min(0.98, max(0, presentationSeconds / durationSeconds))
          if fraction - lastProgressFraction >= 0.02 || now - lastProgressAt >= 100_000_000 {
            emitProgress(fraction, stage: "encoding")
            lastProgressFraction = fraction
            lastProgressAt = now
          }
        }
      } else {
        let waitStarted = DispatchTime.now().uptimeNanoseconds
        Thread.sleep(forTimeInterval: 0.001)
        metrics.writerBackpressureNanoseconds += DispatchTime.now().uptimeNanoseconds - waitStarted
        metrics.writerBackpressureCount += 1
      }
    }
    metrics.loopNanoseconds = DispatchTime.now().uptimeNanoseconds - loopStarted
    if isCancelled() { return cancelledResult() }
    let finishStarted = DispatchTime.now().uptimeNanoseconds
    writerInput.markAsFinished()
    if reader.status == .failed {
      writer.cancelWriting()
      clearCurrent()
      throw PluginError.readFailed(reader.error)
    }

    let semaphore = DispatchSemaphore(value: 0)
    writer.finishWriting { semaphore.signal() }
    semaphore.wait()
    metrics.finishWritingNanoseconds = DispatchTime.now().uptimeNanoseconds - finishStarted
    if isCancelled() { return cancelledResult() }
    clearCurrent()
    guard writer.status == .completed else {
      throw PluginError.writeFailed(writer.error)
    }

    if fileSize(outputPath) >= fileSize(inputPath) {
      try? FileManager.default.removeItem(at: outputURL)
      throw PluginError.noSizeReduction
    }
    if isCancelled() { return cancelledResult() }

    emitProgress(1, stage: "finalizing")

    let success = terminalResult(
      terminal: "succeeded",
      inputPath: inputPath,
      outputPath: outputPath,
      codec: codecName,
      requestedBitrate: averageBitrate,
      appliedBitrate: appliedBitrate,
      width: targetGeometry.displayWidth,
      height: targetGeometry.displayHeight,
      passthrough: passthrough,
      started: started,
      sourceIsHDR: sourceIsHDR,
      hdrPolicy: hdrPolicy,
      toneMapToSdr: toneMapToSdr,
      metrics: metrics
    )
    outputAccepted = true
    return success
  }

  private func terminalResult(
    terminal: String,
    inputPath: String,
    outputPath: String,
    codec: String,
    requestedBitrate: Int,
    appliedBitrate: Int,
    width: Int,
    height: Int,
    passthrough: Bool,
    started: DispatchTime,
    sourceIsHDR: Bool,
    hdrPolicy: String,
    toneMapToSdr: Bool,
    metrics: VideoPipelineMetrics
  ) -> [String: Any] {
    let inputBytes = (try? FileManager.default.attributesOfItem(atPath: inputPath)[.size] as? NSNumber) ?? nil
    let outputBytes = (try? FileManager.default.attributesOfItem(atPath: outputPath)[.size] as? NSNumber) ?? nil
    let elapsed = DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds
    var actualSettings: [String: Any] = [
      "codecRequested": codec,
      "averageBitrateRequested": requestedBitrate,
      "averageBitrateApplied": appliedBitrate,
      "widthRequested": width,
      "heightRequested": height,
      "audioRemoved": true,
      "sourceHdrDetected": sourceIsHDR,
      "hdrPolicyRequested": hdrPolicy,
      "hdrHandling": toneMapToSdr ? "tone-map-to-sdr" : "none",
      "videoProcessing": passthrough ? "passthrough" : "transcode",
      "performance": metrics.asMap(),
      "input": outputProbe(inputPath)
    ]
    if terminal == "succeeded" {
      let output = outputProbe(outputPath)
      actualSettings["output"] = output
      output.forEach { actualSettings[$0.key] = $0.value }
    }
    var warnings = [
      "estimatedDataRate is container metadata; benchmark decisions still require ffprobe/VMAF"
    ]
    if passthrough {
      warnings.append(
        "source video bitrate was already below the requested target; compressed video samples were copied without re-encoding"
      )
    } else if appliedBitrate < requestedBitrate {
      warnings.append(
        "averageBitrate capped from \(requestedBitrate) to \(appliedBitrate) to stay below source bitrate"
      )
    }
    if toneMapToSdr {
      warnings.append(
        "HDR pixels were rendered through the Apple BT.709 SDR composition before H.264 encoding"
      )
    } else if sourceIsHDR && !passthrough {
      warnings.append(
        "HDR source was decoded to 8-bit; color accuracy and HDR preservation are not validated for this transcode"
      )
    }
    return [
      "schemaVersion": 1,
      "terminal": terminal,
      "executor": "apple-avassetreader-writer-v0",
      "outputPath": outputPath,
      "elapsedMilliseconds": Int(elapsed / 1_000_000),
      "inputBytes": inputBytes?.intValue ?? 0,
      "outputBytes": outputBytes?.intValue ?? 0,
      "actualSettings": actualSettings,
      "warnings": warnings
    ]
  }

  private func sdrColorProperties() -> [String: String] {
    [
      AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
      AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
      AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
    ]
  }

  private func sdrVideoComposition(
    asset: AVAsset,
    track: AVAssetTrack,
    geometry: VideoGeometry
  ) -> AVMutableVideoComposition {
    let composition = AVMutableVideoComposition()
    composition.renderSize = CGSize(
      width: geometry.encodedWidth,
      height: geometry.encodedHeight
    )
    let nominalRate = Double(track.nominalFrameRate)
    composition.frameDuration = nominalRate.isFinite && nominalRate > 0
      ? CMTimeMakeWithSeconds(1.0 / nominalRate, preferredTimescale: 60_000)
      : CMTime(value: 1, timescale: 30)
    composition.sourceTrackIDForFrameTiming = track.trackID
    let instruction = AVMutableVideoCompositionInstruction()
    instruction.timeRange = CMTimeRange(start: .zero, duration: asset.duration)
    instruction.layerInstructions = [
      AVMutableVideoCompositionLayerInstruction(assetTrack: track)
    ]
    composition.instructions = [instruction]
    composition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
    composition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
    composition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
    return composition
  }

  private func adaptiveBitrate(
    requested: Int,
    inputPath: String,
    estimatedDataRate: Double,
    durationMilliseconds: Int
  ) -> Int {
    var ceilings: [Double] = []
    if estimatedDataRate > 0 {
      ceilings.append(estimatedDataRate * 0.75)
    }
    if durationMilliseconds > 0 {
      let totalRate = Double(fileSize(inputPath)) * 8_000.0 / Double(durationMilliseconds)
      ceilings.append(totalRate * 0.75)
    }
    guard let ceiling = ceilings.min(), ceiling.isFinite, ceiling > 0 else {
      return requested
    }
    return max(1, min(requested, Int(ceiling.rounded(.down))))
  }

  private func fileSize(_ path: String) -> Int64 {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
          let value = attributes[.size] as? NSNumber else {
      return 0
    }
    return value.int64Value
  }

  private func validateDistinctPaths(_ input: URL, _ output: URL) throws {
    if input.standardizedFileURL.resolvingSymlinksInPath()
      == output.standardizedFileURL.resolvingSymlinksInPath() {
      throw PluginError.invalidRequest
    }
    let inputAttributes = try? FileManager.default.attributesOfItem(atPath: input.path)
    let outputAttributes = try? FileManager.default.attributesOfItem(atPath: output.path)
    if let inputDevice = inputAttributes?[.systemNumber] as? NSNumber,
       let inputFile = inputAttributes?[.systemFileNumber] as? NSNumber,
       let outputDevice = outputAttributes?[.systemNumber] as? NSNumber,
       let outputFile = outputAttributes?[.systemFileNumber] as? NSNumber,
       inputDevice == outputDevice && inputFile == outputFile {
      throw PluginError.invalidRequest
    }
  }

  private func trackCodecName(_ track: AVAssetTrack) -> String? {
    guard let rawDescription = track.formatDescriptions.first else { return nil }
    let description = rawDescription as! CMFormatDescription
    switch CMFormatDescriptionGetMediaSubType(description) {
    case kCMVideoCodecType_H264: return "h264"
    case kCMVideoCodecType_HEVC: return "hevc"
    default: return nil
    }
  }

  /// Resolves a short-side cap against the real source geometry.
  ///
  /// The cap is expressed in display orientation, but the encoder consumes
  /// pixels in the track's encoded orientation, so the ratio is measured on the
  /// display side and applied to the encoded side. Sources already at or below
  /// the cap are returned untouched — this never upscales.
  private func scaledGeometry(
    _ source: VideoGeometry,
    maxShortSide: Int?
  ) -> VideoGeometry {
    let sourceShortSide = min(source.displayWidth, source.displayHeight)
    guard let maxShortSide,
          maxShortSide > 0,
          sourceShortSide > maxShortSide else {
      return source
    }
    let scale = Double(maxShortSide) / Double(sourceShortSide)
    let encodedWidth = evenDimension(Double(source.encodedWidth) * scale)
    let encodedHeight = evenDimension(Double(source.encodedHeight) * scale)
    // preferredTransform only ever rotates by a multiple of 90 degrees, so the
    // display pair is either the encoded pair or its swap.
    let swapped = source.displayWidth == source.encodedHeight
      && source.displayHeight == source.encodedWidth
    return VideoGeometry(
      encodedWidth: encodedWidth,
      encodedHeight: encodedHeight,
      displayWidth: swapped ? encodedHeight : encodedWidth,
      displayHeight: swapped ? encodedWidth : encodedHeight
    )
  }

  /// H.264/HEVC 4:2:0 chroma planes are half resolution, so both edges must be
  /// even or the encoder pads the frame behind our back.
  private func evenDimension(_ value: Double) -> Int {
    let rounded = Int(value.rounded())
    return max(2, rounded - rounded % 2)
  }

  private func videoGeometry(_ track: AVAssetTrack) -> VideoGeometry {
    var encodedWidth = Int(abs(track.naturalSize.width).rounded())
    var encodedHeight = Int(abs(track.naturalSize.height).rounded())

    if (encodedWidth == 0 || encodedHeight == 0),
       let rawDescription = track.formatDescriptions.first {
      let dimensions = CMVideoFormatDescriptionGetDimensions(
        rawDescription as! CMVideoFormatDescription
      )
      encodedWidth = Int(abs(dimensions.width))
      encodedHeight = Int(abs(dimensions.height))
    }

    let encodedRect = CGRect(
      x: 0,
      y: 0,
      width: encodedWidth,
      height: encodedHeight
    )
    let displayRect = encodedRect
      .applying(track.preferredTransform)
      .standardized
    let displayWidth = max(1, Int(abs(displayRect.width).rounded()))
    let displayHeight = max(1, Int(abs(displayRect.height).rounded()))

    return VideoGeometry(
      encodedWidth: max(1, encodedWidth),
      encodedHeight: max(1, encodedHeight),
      displayWidth: displayWidth,
      displayHeight: displayHeight
    )
  }

  private func outputProbe(_ outputPath: String) -> [String: Any] {
    let asset = AVURLAsset(url: URL(fileURLWithPath: outputPath))
    guard let track = asset.tracks(withMediaType: .video).first else { return [:] }
    let geometry = videoGeometry(track)
    let durationSeconds = CMTimeGetSeconds(asset.duration)
    var probe: [String: Any] = [
      "width": geometry.displayWidth,
      "height": geometry.displayHeight,
      "encodedWidth": geometry.encodedWidth,
      "encodedHeight": geometry.encodedHeight,
      "nominalFrameRate": Double(track.nominalFrameRate),
      "estimatedDataRate": Double(track.estimatedDataRate)
    ]
    if durationSeconds.isFinite {
      probe["durationMilliseconds"] = Int(max(0, durationSeconds) * 1000)
    }
    if let rawDescription = track.formatDescriptions.first {
      let description = rawDescription as! CMFormatDescription
      switch CMFormatDescriptionGetMediaSubType(description) {
      case kCMVideoCodecType_H264:
        probe["codec"] = "h264"
      case kCMVideoCodecType_HEVC:
        probe["codec"] = "hevc"
      default:
        probe["codec"] = "unknown"
      }
      probe.merge(colorMetadata(description)) { _, new in new }
    }
    return probe
  }

  private func isHDRTrack(_ track: AVAssetTrack) -> Bool {
    if track.hasMediaCharacteristic(.containsHDRVideo) { return true }
    for rawDescription in track.formatDescriptions {
      let metadata = colorMetadata(rawDescription as! CMFormatDescription)
      let primaries = metadata["colorPrimaries"]?.uppercased() ?? ""
      let transfer = metadata["transferFunction"]?.uppercased() ?? ""
      if primaries.contains("2020") || transfer.contains("HLG")
        || transfer.contains("2084") || transfer.contains("PQ") {
        return true
      }
    }
    return false
  }

  private func colorMetadata(_ description: CMFormatDescription) -> [String: String] {
    let extensions = (CMFormatDescriptionGetExtensions(description) as NSDictionary?) ?? NSDictionary()
    var values: [String: String] = [:]
    let fields: [(String, CFString)] = [
      ("colorPrimaries", kCMFormatDescriptionExtension_ColorPrimaries),
      ("transferFunction", kCMFormatDescriptionExtension_TransferFunction),
      ("yCbCrMatrix", kCMFormatDescriptionExtension_YCbCrMatrix)
    ]
    for (name, key) in fields {
      if let value = extensions[key as String] as? String {
        values[name] = value
      }
    }
    return values
  }

  private func emitProgress(_ fraction: Double, stage: String) {
    let value = min(1, max(0, fraction))
    DispatchQueue.main.async { [weak self] in
      self?.progressSink?(["fraction": value, "stage": stage])
    }
  }

  public func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    progressSink = events
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    progressSink = nil
    return nil
  }

  private func cancel() {
    stateLock.lock()
    if busy { cancelled = true }
    stateLock.unlock()
  }

  private func beginTask() -> Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    guard !busy else { return false }
    busy = true
    cancelled = false
    return true
  }

  private func finishTask() {
    stateLock.lock()
    currentReader = nil
    currentWriter = nil
    busy = false
    cancelled = false
    stateLock.unlock()
  }

  private func isCancelled() -> Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    return cancelled
  }

  private func clearCurrent() {
    stateLock.lock()
    currentReader = nil
    currentWriter = nil
    stateLock.unlock()
  }
}

private struct VideoPipelineMetrics {
  var setupNanoseconds: UInt64 = 0
  var startWritingNanoseconds: UInt64 = 0
  var loopNanoseconds: UInt64 = 0
  var readerCallNanoseconds: UInt64 = 0
  var writerAppendNanoseconds: UInt64 = 0
  var writerBackpressureNanoseconds: UInt64 = 0
  var finishWritingNanoseconds: UInt64 = 0
  var sampleCount = 0
  var writerBackpressureCount = 0

  func asMap() -> [String: Any] {
    func milliseconds(_ nanoseconds: UInt64) -> Double {
      Double(nanoseconds) / 1_000_000
    }
    return [
      "setupMilliseconds": milliseconds(setupNanoseconds),
      "startWritingMilliseconds": milliseconds(startWritingNanoseconds),
      "loopMilliseconds": milliseconds(loopNanoseconds),
      "readerCallMilliseconds": milliseconds(readerCallNanoseconds),
      "writerAppendMilliseconds": milliseconds(writerAppendNanoseconds),
      "writerBackpressureMilliseconds": milliseconds(writerBackpressureNanoseconds),
      "finishWritingMilliseconds": milliseconds(finishWritingNanoseconds),
      "sampleCount": sampleCount,
      "writerBackpressureCount": writerBackpressureCount,
      "measurementNote": "Call wall time is not hardware decode/encode time; codec work may overlap"
    ]
  }
}

private struct VideoGeometry {
  let encodedWidth: Int
  let encodedHeight: Int
  let displayWidth: Int
  let displayHeight: Int
}

private enum PluginError: LocalizedError {
  case hdrProtected
  case invalidRequest
  case noVideoTrack
  case readerConfiguration
  case writerConfiguration
  case startFailed(Error?)
  case appendFailed(Error?)
  case readFailed(Error?)
  case writeFailed(Error?)
  case noSizeReduction
  case unsupported(String)

  var code: String {
    if case .hdrProtected = self { return "HDR_COLOR_PRESERVATION" }
    return "VIDEO_COMPRESSION_FAILED"
  }

  var errorDescription: String? {
    switch self {
    case .hdrProtected: return "HDR source kept unchanged; this route cannot verify color-preserving transcoding"
    case .invalidRequest: return "Invalid video compression request"
    case .noVideoTrack: return "Input has no video track"
    case .readerConfiguration: return "AVAssetReader rejected the video output"
    case .writerConfiguration: return "AVAssetWriter rejected the video input"
    case .startFailed(let error): return "Could not start transcoding: \(error?.localizedDescription ?? "unknown")"
    case .appendFailed(let error): return "Could not append video frame: \(error?.localizedDescription ?? "unknown")"
    case .readFailed(let error): return "Video read failed: \(error?.localizedDescription ?? "unknown")"
    case .writeFailed(let error): return "Video write failed: \(error?.localizedDescription ?? "unknown")"
    case .noSizeReduction: return "Compression produced no size reduction; the larger output was removed"
    case .unsupported(let detail): return detail
    }
  }
}
