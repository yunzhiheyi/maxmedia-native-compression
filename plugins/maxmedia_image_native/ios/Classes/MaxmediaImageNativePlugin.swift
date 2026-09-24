import UIKit
import Accelerate
import Flutter
import ImageIO
import UniformTypeIdentifiers
import libwebp

public class MaxmediaImageNativePlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private static var batchProgressSink: FlutterEventSink?

  private let registryLock = NSLock()
  private var activeOperations = Set<String>()
  private var cancelledOperations = Set<String>()

  private func register(_ operationId: String) {
    registryLock.lock()
    activeOperations.insert(operationId)
    registryLock.unlock()
  }

  private func unregister(_ operationId: String) {
    registryLock.lock()
    activeOperations.remove(operationId)
    cancelledOperations.remove(operationId)
    registryLock.unlock()
  }

  // Consuming the flag means the first reached checkpoint wins; later
  // checkpoints see a clean state.
  private func isCancelled(_ operationId: String?) -> Bool {
    guard let operationId else { return false }
    registryLock.lock()
    defer { registryLock.unlock() }
    return cancelledOperations.remove(operationId) != nil
  }

  private func cancelOperations(_ ids: [String]?) {
    registryLock.lock()
    defer { registryLock.unlock() }
    if let ids {
      for id in ids where activeOperations.contains(id) {
        cancelledOperations.insert(id)
      }
    } else {
      cancelledOperations.formUnion(activeOperations)
    }
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "maxmedia_image_native",
      binaryMessenger: registrar.messenger()
    )
    registrar.addMethodCallDelegate(MaxmediaImageNativePlugin(), channel: channel)
    let progressChannel = FlutterEventChannel(
      name: "maxmedia_image_native/batch_progress",
      binaryMessenger: registrar.messenger()
    )
    progressChannel.setStreamHandler(MaxmediaImageNativePlugin())
  }

  public func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    MaxmediaImageNativePlugin.batchProgressSink = events
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    MaxmediaImageNativePlugin.batchProgressSink = nil
    return nil
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "capabilities":
      result(capabilities())
    case "compress":
      guard let arguments = call.arguments as? [String: Any] else {
        result(FlutterError(code: "INVALID_ARGUMENT", message: "Expected request map", details: nil))
        return
      }
      let operationId = arguments["operationId"] as? String
      if let operationId { register(operationId) }
      DispatchQueue.global(qos: .userInitiated).async {
        defer { if let operationId { self.unregister(operationId) } }
        do {
          let value = try self.compress(arguments)
          DispatchQueue.main.async { result(value) }
        } catch {
          DispatchQueue.main.async {
            result(FlutterError(
              code: (error as? PluginError)?.code ?? "IMAGE_COMPRESSION_FAILED",
              message: error.localizedDescription,
              details: nil
            ))
          }
        }
      }
    case "compressBatch":
      guard let arguments = call.arguments as? [String: Any],
            let requests = arguments["requests"] as? [[String: Any]],
            !requests.isEmpty else {
        result(FlutterError(code: "INVALID_ARGUMENT", message: "Expected a non-empty requests list", details: nil))
        return
      }
      guard batchPathsAreDistinct(requests) else {
        result(FlutterError(code: "INVALID_ARGUMENT",
                            message: "Batch outputs must not alias any input or another output",
                            details: nil))
        return
      }
      registryLock.lock()
      activeOperations.formUnion(requests.compactMap { $0["operationId"] as? String })
      registryLock.unlock()
      compressBatch(requests, batchId: arguments["batchId"] as? String,
                    maxConcurrent: arguments["maxConcurrent"] as? Int, result: result)
    case "cancelImageCompression":
      let arguments = call.arguments as? [String: Any]
      cancelOperations(arguments?["operationIds"] as? [String])
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// Fans requests out over the global concurrent queue and answers once with
  /// one outcome per request in input order. A failing item never fails the
  /// batch. Decoding full-resolution images multiplies peak memory, so at
  /// most four run in parallel.
  private func compressBatch(
    _ requests: [[String: Any]],
    batchId: String?,
    maxConcurrent: Int?,
    result: @escaping FlutterResult
  ) {
    let total = requests.count
    var outcomes = [Any?](repeating: nil, count: total)
    let lock = NSLock()
    let group = DispatchGroup()
    // Caller-configurable concurrency, clamped to the same memory-safe
    // envelope the Android worker pool uses.
    let gate = DispatchSemaphore(value: max(1, min(8, maxConcurrent ?? 4)))
    var completed = 0

    for (index, request) in requests.enumerated() {
      group.enter()
      DispatchQueue.global(qos: .userInitiated).async { [weak self] in
        defer {
          group.leave()
          if let operationId = request["operationId"] as? String {
            self?.unregister(operationId)
          }
        }
        gate.wait()
        defer { gate.signal() }
        guard let self else {
          lock.lock()
          outcomes[index] = ["index": index, "error": "plugin released"]
          lock.unlock()
          return
        }
        let outcome: [String: Any]
        do {
          outcome = ["index": index, "result": try self.compress(request)]
        } catch {
          if case PluginError.cancelled = error {
            let startedAll = DispatchTime.now()
            outcome = [
              "index": index,
              "result": self.cancelledResult(
                request, started: startedAll
              ),
            ]
          } else {
            outcome = ["index": index, "error": error.localizedDescription]
          }
        }
        lock.lock()
        outcomes[index] = outcome
        completed += 1
        let finished = completed
        let terminal = (outcome["result"] as? [String: Any])?["terminal"]
          as? String ?? "failed"
        lock.unlock()
        DispatchQueue.main.async {
          MaxmediaImageNativePlugin.batchProgressSink?([
            "batchId": batchId ?? "",
            "completed": finished,
            "total": total,
            "index": index,
            "terminal": terminal,
          ])
        }
      }
    }
    group.notify(queue: .main) {
      result(["results": outcomes])
    }
  }

  private func cancelledResult(
    _ arguments: [String: Any],
    started: DispatchTime
  ) -> [String: Any] {
    let elapsed = DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds
    let format = arguments["format"] as? String ?? "jpeg"
    return [
      "schemaVersion": 1,
      "terminal": "cancelled",
      "executor": format == "webp" ? "libwebp" : "apple-imageio",
      "outputPath": arguments["outputPath"] as? String ?? "",
      "elapsedMilliseconds": Int(elapsed / 1_000_000),
      "inputBytes": 0,
      "outputBytes": 0,
      "actualSettings": [
        "format": format,
        "qualityRequested": arguments["quality"] as? Double ?? 0,
        "cancelled": true
      ],
      "warnings": [
        "Compression was cancelled; decoded pixel memory was released immediately"
      ]
    ]
  }

  private func capabilities() -> [String: Any] {
    let identifiers = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
    var formats = ["jpeg", "png", "webp"]
    if identifiers.contains(UTType.heic.identifier) { formats.append("heic") }
    return [
      "schemaVersion": 1,
      "executor": "apple-imageio+libwebp",
      "platform": "ios",
      "features": [
        "resize", "social-resize", "quality", "adaptive-quality-two-pass",
        "metadata-best-effort", "webp-lossy", "batch-compress", "cancel"
      ],
      "codecs": [],
      "formats": formats,
      "warnings": ["Metadata preservation is semantic and best-effort after resizing"]
    ]
  }

  private func compress(_ arguments: [String: Any]) throws -> [String: Any] {
    guard (arguments["schemaVersion"] as? Int) == 1,
          let inputPath = arguments["inputPath"] as? String,
          let outputPath = arguments["outputPath"] as? String,
          let format = arguments["format"] as? String,
          let quality = arguments["quality"] as? Double,
          quality >= 0, quality <= 1 else {
      throw PluginError.invalidRequest
    }
    let targetCompressionRatio = arguments["targetCompressionRatio"] as? Double
    let minimumQuality = arguments["minimumQuality"] as? Double
    guard (targetCompressionRatio == nil) == (minimumQuality == nil) else {
      throw PluginError.invalidRequest
    }
    if let targetCompressionRatio, let minimumQuality {
      guard targetCompressionRatio > 0, targetCompressionRatio < 1,
            minimumQuality >= 0, minimumQuality <= quality else {
        throw PluginError.invalidRequest
      }
    }
    let operationId = arguments["operationId"] as? String
    let startedAll = DispatchTime.now()
    if isCancelled(operationId) {
      return cancelledResult(arguments, started: startedAll)
    }

    let inputURL = URL(fileURLWithPath: inputPath)
    let outputURL = URL(fileURLWithPath: outputPath)
    try validateDistinctPaths(inputURL, outputURL)
    guard let source = CGImageSourceCreateWithURL(inputURL as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let sourceWidth = properties[kCGImagePropertyPixelWidth] as? Int,
          let sourceHeight = properties[kCGImagePropertyPixelHeight] as? Int else {
      throw PluginError.decodeFailed
    }

    let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
    let swapsAxes = (5...8).contains(orientation)
    let displayWidth = swapsAxes ? sourceHeight : sourceWidth
    let displayHeight = swapsAxes ? sourceWidth : sourceHeight
    let resizePolicy = arguments["resizePolicy"] as? String ?? "original"
    guard resizePolicy == "original" || resizePolicy == "social" else {
      throw PluginError.invalidRequest
    }
    let socialTarget = resizePolicy == "social"
      ? socialTarget(width: displayWidth, height: displayHeight)
      : nil
    let requestedMaxWidth = arguments["maxWidth"] as? Int
    let requestedMaxHeight = arguments["maxHeight"] as? Int
    let maxWidth = [requestedMaxWidth, socialTarget?.width].compactMap { $0 }.min()
    let maxHeight = [requestedMaxHeight, socialTarget?.height].compactMap { $0 }.min()
    let limit = min(
      maxWidth.map { Double($0) / Double(displayWidth) } ?? 1,
      maxHeight.map { Double($0) / Double(displayHeight) } ?? 1
    )
    let scale = min(1, limit)
    let outputWidth = max(1, Int((Double(displayWidth) * scale).rounded()))
    let outputHeight = max(1, Int((Double(displayHeight) * scale).rounded()))
    let normalizeOrientation = scale < 1 || orientation != 1 || format == "webp"

    let image: CGImage?
    if normalizeOrientation {
      let maxPixel = max(outputWidth, outputHeight)
      image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixel
      ] as CFDictionary)
    } else {
      image = CGImageSourceCreateImageAtIndex(source, 0, [
        kCGImageSourceShouldCache: false
      ] as CFDictionary)
    }
    guard let image else { throw PluginError.decodeFailed }
    let finalWidth = image.width
    let finalHeight = image.height
    let colorPolicy = arguments["colorPolicy"] as? String ?? "keepOriginal"
    guard colorPolicy == "keepOriginal" || colorPolicy == "allowConversion" else {
      throw PluginError.invalidRequest
    }
    let profileName = (properties[kCGImagePropertyProfileName] as? String)
      ?? (properties[kCGImagePropertyNamedColorSpace] as? String)
      ?? (image.colorSpace?.name as String?)
    let normalizedProfile = profileName?.lowercased() ?? ""
    let requiresProfile = colorPolicy == "keepOriginal"
      && !normalizedProfile.isEmpty
      && !normalizedProfile.contains("srgb")
      && !normalizedProfile.contains("gray")
      && !normalizedProfile.contains("grey")
      && !normalizedProfile.contains("devicergb")
    if requiresProfile && format == "webp" {
      throw PluginError.colorProtected
    }

    try FileManager.default.createDirectory(
      at: outputURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let preserveMetadata = arguments["preserveMetadata"] as? Bool ?? false
    var warnings: [String] = []
    let inputBytes = try FileManager.default.attributesOfItem(atPath: inputPath)[.size] as? NSNumber
    let destinationType: String?
    if format == "webp" {
      destinationType = nil
    } else {
      destinationType = try typeIdentifier(format)
      let supported = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
      guard supported.contains(destinationType!) else { throw PluginError.unsupportedFormat(format) }
    }
    let webPPixels = format == "webp" ? try prepareWebPPixels(image) : nil
    var outputPrepared = false
    var outputAccepted = false
    defer {
      if outputPrepared && !outputAccepted {
        try? FileManager.default.removeItem(at: outputURL)
      }
    }
    // Decode and resize are done; a cancel here must not spend the encode.
    // Falling out of scope frees the CGImage and pixel buffer immediately.
    if isCancelled(operationId) {
      return cancelledResult(arguments, started: startedAll)
    }
    func encode(quality appliedQuality: Double) throws {
      outputPrepared = true
      try? FileManager.default.removeItem(at: outputURL)
      if let webPPixels {
        try encodeWebP(webPPixels, quality: appliedQuality, outputURL: outputURL)
        return
      }
      guard let destination = CGImageDestinationCreateWithURL(
        outputURL as CFURL,
        destinationType! as CFString,
        1,
        nil
      ) else {
        throw PluginError.destinationFailed
      }

      var outputProperties: [CFString: Any] = [
        kCGImageDestinationLossyCompressionQuality: max(0, min(1, appliedQuality))
      ]
      if preserveMetadata {
        outputProperties.merge(properties) { current, _ in current }
        outputProperties[kCGImagePropertyPixelWidth] = finalWidth
        outputProperties[kCGImagePropertyPixelHeight] = finalHeight
        if normalizeOrientation {
          outputProperties[kCGImagePropertyOrientation] = 1
        }
      }
      CGImageDestinationAddImage(destination, image, outputProperties as CFDictionary)
      guard CGImageDestinationFinalize(destination) else {
        throw PluginError.destinationFailed
      }
    }

    let isLossy = format == "jpeg" || format == "webp" || format == "heic"
    var appliedQuality = quality
    var adaptiveAttempts = 1
    let started = DispatchTime.now()
    try encode(quality: appliedQuality)
    var outputBytes = try FileManager.default.attributesOfItem(atPath: outputPath)[.size] as? NSNumber
    // Abort between the two encodes; the first-pass output is removed so a
    // cancelled request never leaves a file behind.
    if isCancelled(operationId) {
      try? FileManager.default.removeItem(at: outputURL)
      return cancelledResult(arguments, started: startedAll)
    }
    if isLossy,
       let targetCompressionRatio,
       let minimumQuality,
       let inputByteCount = inputBytes?.doubleValue,
       inputByteCount > 0 {
      let firstRatio = Double(outputBytes?.intValue ?? 0) / inputByteCount
      if firstRatio > targetCompressionRatio && quality > minimumQuality {
        let estimated = quality * targetCompressionRatio / firstRatio
        let bounded = max(minimumQuality, min(quality, estimated))
        let fallbackQuality = max(minimumQuality, (bounded * 100).rounded() / 100)
        if fallbackQuality < quality {
          appliedQuality = fallbackQuality
          adaptiveAttempts = 2
          try encode(quality: appliedQuality)
          outputBytes = try FileManager.default.attributesOfItem(atPath: outputPath)[.size] as? NSNumber
          warnings.append("Image quality was adapted once while reusing the decoded pixels")
        }
      }
      let finalRatio = Double(outputBytes?.intValue ?? 0) / inputByteCount
      if finalRatio > targetCompressionRatio {
        warnings.append("The two-pass quality budget did not reach the target size reduction")
      }
    }
    if isCancelled(operationId) {
      try? FileManager.default.removeItem(at: outputURL)
      return cancelledResult(arguments, started: startedAll)
    }
    if targetCompressionRatio != nil,
       let inputBytes, let outputBytes,
       outputBytes.intValue >= inputBytes.intValue {
      try? FileManager.default.removeItem(at: outputURL)
      throw PluginError.noSizeReduction
    }
    if requiresProfile {
      guard let outputSource = CGImageSourceCreateWithURL(outputURL as CFURL, nil),
            let outputProperties = CGImageSourceCopyPropertiesAtIndex(outputSource, 0, nil) as? [CFString: Any],
            let outputProfile = (outputProperties[kCGImagePropertyProfileName] as? String)
              ?? (outputProperties[kCGImagePropertyNamedColorSpace] as? String),
            outputProfile.caseInsensitiveCompare(profileName!) == .orderedSame,
            let sourceICC = image.colorSpace?.copyICCData(),
            let outputImage = CGImageSourceCreateThumbnailAtIndex(outputSource, 0, [
              kCGImageSourceCreateThumbnailFromImageAlways: true,
              kCGImageSourceThumbnailMaxPixelSize: 2
            ] as CFDictionary),
            let outputICC = outputImage.colorSpace?.copyICCData(),
            CFEqual(sourceICC, outputICC) else {
        throw PluginError.colorProtected
      }
    }
    if format == "webp" && preserveMetadata {
      warnings.append("WebP metadata was not preserved by the libwebp route")
    }
    if scale < 1 && preserveMetadata && format != "webp" {
      warnings.append("Metadata preservation after resize is best-effort")
    }
    if resizePolicy == "social" && scale < 1 {
      warnings.append("Social resize policy reduced pixel dimensions before encoding")
    }

    let elapsed = DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds
    var actualSettings: [String: Any] = [
      "format": format,
      "quality": appliedQuality,
      "qualityRequested": quality,
      "qualityApplied": appliedQuality,
      "adaptiveAttempts": adaptiveAttempts,
      "totalElapsedMilliseconds": Int(
        (DispatchTime.now().uptimeNanoseconds - startedAll.uptimeNanoseconds) / 1_000_000
      ),
      "inputWidth": displayWidth,
      "inputHeight": displayHeight,
      "width": finalWidth,
      "height": finalHeight,
      "metadataPreserved": preserveMetadata && format != "webp",
      "colorPolicy": colorPolicy,
      "orientationNormalized": normalizeOrientation,
      "resizePolicy": resizePolicy,
      "socialResizeApplied": resizePolicy == "social" && scale < 1
    ]
    if let targetCompressionRatio, isLossy {
      actualSettings["targetCompressionRatio"] = targetCompressionRatio
    }
    if let minimumQuality, isLossy {
      actualSettings["minimumUsefulQuality"] = minimumQuality
    }
    outputAccepted = true
    return [
      "schemaVersion": 1,
      "terminal": "succeeded",
      "executor": format == "webp" ? "libwebp" : "apple-imageio",
      "outputPath": outputPath,
      "elapsedMilliseconds": Int(elapsed / 1_000_000),
      "inputBytes": inputBytes?.intValue ?? 0,
      "outputBytes": outputBytes?.intValue ?? 0,
      "actualSettings": actualSettings,
      "warnings": warnings
    ]
  }

  private func prepareWebPPixels(_ image: CGImage) throws -> WebPPixelBuffer {
    let width = image.width
    let height = image.height
    let bytesPerRow = width * 4
    let hasAlpha = imageHasAlpha(image)
    var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
    guard let context = CGContext(
      data: &pixels,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: bytesPerRow,
      // WebP simple encoding does not write ICC. Convert every source (gray,
      // CMYK and wide gamut included) into the declared sRGB pixel space.
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue |
        CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
      throw PluginError.destinationFailed
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    if hasAlpha {
      var unpremultiplied = [UInt8](repeating: 0, count: pixels.count)
      let conversionError = pixels.withUnsafeMutableBytes { sourceBytes in
        unpremultiplied.withUnsafeMutableBytes { destinationBytes in
          var source = vImage_Buffer(
            data: sourceBytes.baseAddress,
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: bytesPerRow
          )
          var destination = vImage_Buffer(
            data: destinationBytes.baseAddress,
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: bytesPerRow
          )
          return vImageUnpremultiplyData_RGBA8888(
            &source,
            &destination,
            vImage_Flags(kvImageNoFlags)
          )
        }
      }
      guard conversionError == kvImageNoError else { throw PluginError.destinationFailed }
      pixels = unpremultiplied
    }

    return WebPPixelBuffer(
      pixels: pixels,
      width: width,
      height: height,
      bytesPerRow: bytesPerRow
    )
  }

  private func encodeWebP(
    _ buffer: WebPPixelBuffer,
    quality: Double,
    outputURL: URL
  ) throws {
    var encodedBytes: UnsafeMutablePointer<UInt8>?
    let encodedSize = buffer.pixels.withUnsafeBytes { pixels in
      WebPEncodeRGBA(
        pixels.bindMemory(to: UInt8.self).baseAddress,
        Int32(buffer.width),
        Int32(buffer.height),
        Int32(buffer.bytesPerRow),
        Float(max(0, min(1, quality)) * 100),
        &encodedBytes
      )
    }
    guard encodedSize > 0, let encodedBytes else { throw PluginError.destinationFailed }
    defer { WebPFree(encodedBytes) }
    let encodedData = Data(bytes: encodedBytes, count: encodedSize)
    try encodedData.write(to: outputURL, options: .atomic)
  }

  private func imageHasAlpha(_ image: CGImage) -> Bool {
    switch image.alphaInfo {
    case .premultipliedFirst, .premultipliedLast, .first, .last, .alphaOnly:
      return true
    case .none, .noneSkipFirst, .noneSkipLast:
      return false
    @unknown default:
      return true
    }
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

  private func batchPathsAreDistinct(_ requests: [[String: Any]]) -> Bool {
    let inputs = requests.compactMap { ($0["inputPath"] as? String).map(URL.init(fileURLWithPath:)) }
    let outputs = requests.compactMap { ($0["outputPath"] as? String).map(URL.init(fileURLWithPath:)) }
    guard inputs.count == requests.count, outputs.count == requests.count else { return false }
    for (index, output) in outputs.enumerated() {
      for input in inputs {
        if (try? validateDistinctPaths(input, output)) == nil { return false }
      }
      for previous in outputs.prefix(index) {
        if (try? validateDistinctPaths(previous, output)) == nil { return false }
      }
    }
    return true
  }

  private func socialTarget(width: Int, height: Int) -> (width: Int, height: Int) {
    // Policy adapted from Curzibn/flutter_luban (Apache-2.0), with the
    // never-upscale edge case kept strict for this plugin.
    let shortSide = min(width, height)
    let longSide = max(width, height)
    let ratio = Double(shortSide) / Double(longSide)
    let pixelCount = Double(width) * Double(height)
    var targetShort = 1440
    var targetLong = Int((Double(targetShort) / ratio).rounded())

    if longSide >= 10_800 && ratio > 0.4 {
      targetLong = 1440
      targetShort = Int((Double(targetLong) * ratio).rounded())
    }
    if pixelCount > 40_960_000 {
      let trapShort = Int((Double(shortSide) * 0.25).rounded())
      if trapShort < targetShort {
        targetShort = trapShort
        targetLong = Int((Double(targetShort) / ratio).rounded())
      }
    }
    if targetShort > shortSide {
      targetShort = shortSide
      targetLong = longSide
    }
    let currentPixels = Double(targetShort) * Double(targetLong)
    if currentPixels > 10_240_000 {
      let capScale = floor(sqrt(10_240_000 / currentPixels) * 1000) / 1000
      targetShort = Int((Double(targetShort) * capScale).rounded())
      targetLong = Int((Double(targetLong) * capScale).rounded())
    }
    targetShort = max(1, (targetShort / 2) * 2)
    targetLong = max(1, (targetLong / 2) * 2)
    return width < height
      ? (width: targetShort, height: targetLong)
      : (width: targetLong, height: targetShort)
  }

  private func typeIdentifier(_ format: String) throws -> String {
    switch format {
    case "jpeg": return UTType.jpeg.identifier
    case "png": return UTType.png.identifier
    case "webp": return UTType.webP.identifier
    case "heic": return UTType.heic.identifier
    default: throw PluginError.unsupportedFormat(format)
    }
  }
}

private struct WebPPixelBuffer {
  let pixels: [UInt8]
  let width: Int
  let height: Int
  let bytesPerRow: Int
}

private enum PluginError: LocalizedError {
  case colorProtected
  case invalidRequest
  case decodeFailed
  case destinationFailed
  case unsupportedFormat(String)
  case cancelled
  case noSizeReduction

  var code: String {
    if case .colorProtected = self { return "IMAGE_COLOR_PRESERVATION" }
    return "IMAGE_COMPRESSION_FAILED"
  }

  var errorDescription: String? {
    switch self {
    case .colorProtected: return "Source image kept unchanged; this output cannot verify preservation of its color profile"
    case .invalidRequest: return "Invalid image compression request"
    case .decodeFailed: return "Input image could not be decoded"
    case .destinationFailed: return "Output image could not be written"
    case .unsupportedFormat(let format): return "Unsupported output format: \(format)"
    case .cancelled: return "Image compression was cancelled"
    case .noSizeReduction: return "Image compression produced no size reduction"
    }
  }
}
