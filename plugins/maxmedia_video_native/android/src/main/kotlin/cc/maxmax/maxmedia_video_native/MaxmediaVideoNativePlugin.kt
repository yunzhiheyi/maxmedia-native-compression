package cc.maxmax.maxmedia_video_native

import android.content.Context
import android.media.MediaCodecList
import android.media.MediaCodecInfo
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Handler
import android.os.Looper
import androidx.annotation.OptIn
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.Presentation
import androidx.media3.transformer.Composition
import androidx.media3.transformer.DefaultEncoderFactory
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.Effects
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.ProgressHolder
import androidx.media3.transformer.Transformer
import androidx.media3.transformer.VideoEncoderSettings
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.EventChannel
import java.io.File
import android.system.Os

@OptIn(UnstableApi::class)
class MaxmediaVideoNativePlugin : FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private lateinit var channel: MethodChannel
    private lateinit var progressChannel: EventChannel
    private lateinit var context: Context
    private var transformer: Transformer? = null
    private var pendingResult: MethodChannel.Result? = null
    private var pendingRequest: Map<String, Any?>? = null
    private var startedAtNanos: Long = 0
    private var didComplete = false
    private var progressSink: EventChannel.EventSink? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private var progressRunnable: Runnable? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "maxmedia_video_native")
        channel.setMethodCallHandler(this)
        progressChannel = EventChannel(binding.binaryMessenger, "maxmedia_video_native/progress")
        progressChannel.setStreamHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "capabilities" -> result.success(capabilities())
            "compress" -> start(call, result)
            "cancel" -> {
                cancelCurrent()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun capabilities(): Map<String, Any> {
        val encoders = MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos
            .filter { it.isEncoder }
        val codecs = mutableSetOf<String>()
        val hardwareNames = mutableListOf<String>()
        for (info in encoders) {
            if (info.supportedTypes.any { it.equals(MimeTypes.VIDEO_H264, ignoreCase = true) }) {
                codecs += "h264"
            }
            if (info.supportedTypes.any { it.equals(MimeTypes.VIDEO_H265, ignoreCase = true) }) {
                codecs += "hevc"
            }
            if (android.os.Build.VERSION.SDK_INT >= 29 && info.isHardwareAccelerated) {
                hardwareNames += info.name
            }
        }
        return mapOf(
            "schemaVersion" to 1,
            "executor" to "android-media3-1.11.1-v0",
            "platform" to "android",
            "features" to listOf("average-bitrate", "gop", "cancel", "progress", "audio-optional", "downscale-short-side"),
            "codecs" to codecs.toList().sorted(),
            "formats" to listOf("mp4"),
            "warnings" to listOf(
                "V0 preserves source frame rate; maxShortSide only downscales",
                "Requested encoder settings may be ignored; ffprobe output is required",
                "Hardware encoders: ${hardwareNames.joinToString(",")}",
            ),
        )
    }

    @Suppress("UNCHECKED_CAST")
    private fun start(call: MethodCall, result: MethodChannel.Result) {
        if (pendingResult != null) {
            result.error("BUSY", "Only one export is supported per plugin instance", null)
            return
        }
        val arguments = call.arguments as? Map<String, Any?>
        if (arguments == null || (arguments["schemaVersion"] as? Number)?.toInt() != 1) {
            result.error("INVALID_ARGUMENT", "Expected V1 request map", null)
            return
        }
        if (arguments["container"] != "mp4") {
            result.error("UNSUPPORTED", "Media3 V0 only emits MP4", null)
            return
        }
        if (arguments["width"] != null ||
            arguments["height"] != null ||
            arguments["maxFrameRate"] != null
        ) {
            result.error("UNSUPPORTED", "Use maxShortSide for scaling; frame rate changes are unsupported", null)
            return
        }
        val maxShortSide = (arguments["maxShortSide"] as? Number)?.toInt()
        if (arguments["maxShortSide"] != null && (maxShortSide == null || maxShortSide < 2)) {
            result.error("INVALID_ARGUMENT", "maxShortSide must be at least 2", null)
            return
        }
        val inputPath = arguments["inputPath"] as? String
        val outputPath = arguments["outputPath"] as? String
        val codec = arguments["codec"] as? String
        val hdrPolicy = arguments["hdrPolicy"] as? String ?: "keepOriginal"
        val bitrate = (arguments["averageBitrate"] as? Number)?.toInt()
        val gop = (arguments["gopSeconds"] as? Number)?.toFloat() ?: 2f
        if (inputPath == null || outputPath == null || codec == null || bitrate == null ||
            hdrPolicy !in setOf("keepOriginal", "allowWithWarning", "toneMapToSdr", "rejectH264")) {
            result.error("INVALID_ARGUMENT", "Missing required video field", null)
            return
        }
        if (sameFile(inputPath, outputPath)) {
            result.error("INVALID_ARGUMENT", "Input and output must be different files", null)
            return
        }
        if (hdrPolicy == "rejectH264") {
            result.error(
                "UNSUPPORTED",
                "Android V0 does not support the rejectH264 HDR policy; use keepOriginal to protect HDR sources",
                null,
            )
            return
        }
        if (hdrPolicy == "toneMapToSdr") {
            result.error(
                "UNSUPPORTED",
                "Android V0 does not yet provide an HDR-to-SDR tone-mapping route",
                null,
            )
            return
        }
        if (hdrPolicy == "keepOriginal" && sourceHasHdrMetadata(inputPath) != false) {
            result.error(
                "HDR_COLOR_PRESERVATION",
                "HDR or unverified video color metadata; source kept unchanged because this route cannot guarantee color-preserving transcoding",
                null,
            )
            return
        }

        val inputProbe = probeVideo(inputPath)
        val sourceWidth = (inputProbe["width"] as? Number)?.toInt()
        val sourceHeight = (inputProbe["height"] as? Number)?.toInt()
        if (maxShortSide != null && (sourceWidth == null || sourceHeight == null || sourceWidth <= 0 || sourceHeight <= 0)) {
            result.error("UNSUPPORTED", "Could not determine source dimensions for maxShortSide", null)
            return
        }
        val scaleShortSide = plannedShortSide(maxShortSide, sourceWidth, sourceHeight)
        val appliedBitrate = adaptiveBitrate(bitrate, inputPath, inputProbe)
        val effectiveArguments = arguments.toMutableMap().apply {
            this["averageBitrateApplied"] = appliedBitrate
        }

        val output = File(outputPath)
        output.parentFile?.mkdirs()
        if (output.exists()) output.delete()
        val settings = VideoEncoderSettings.Builder()
            .setBitrate(appliedBitrate)
            .setiFrameIntervalSeconds(gop)
            .build()
        val encoderFactory = DefaultEncoderFactory.Builder(context)
            .setEnableFormatFallback(false)
            .setRequestedVideoEncoderSettings(settings)
            .build()
        val listener = object : Transformer.Listener {
            override fun onCompleted(composition: Composition, exportResult: ExportResult) {
                if (output.length() >= File(inputPath).length()) {
                    output.delete()
                    fail(
                        "NO_SIZE_REDUCTION",
                        "Compression produced no size reduction; the larger output was removed",
                    )
                    return
                }
                complete(
                    resultMap(
                        terminal = "succeeded",
                        request = effectiveArguments,
                        elapsedMilliseconds = elapsedMilliseconds(),
                    ),
                )
            }

            override fun onError(
                composition: Composition,
                exportResult: ExportResult,
                exportException: ExportException,
            ) {
                output.delete()
                fail("VIDEO_COMPRESSION_FAILED", exportException.message ?: "Media3 export failed")
            }
        }
        val mime = if (codec == "hevc") MimeTypes.VIDEO_H265 else MimeTypes.VIDEO_H264
        val instance = Transformer.Builder(context)
            .setVideoMimeType(mime)
            .setEncoderFactory(encoderFactory)
            .setUsePlatformDiagnostics(false)
            .addListener(listener)
            .build()
        val itemBuilder = EditedMediaItem.Builder(MediaItem.fromUri(Uri.fromFile(File(inputPath))))
            .setRemoveAudio(arguments["removeAudio"] as? Boolean ?: false)
        if (scaleShortSide != null) {
            itemBuilder.setEffects(
                Effects(emptyList(), listOf(Presentation.createForShortSide(scaleShortSide))),
            )
        }
        val item = itemBuilder.build()

        pendingResult = result
        pendingRequest = effectiveArguments
        didComplete = false
        startedAtNanos = System.nanoTime()
        transformer = instance
        try {
            instance.start(item, outputPath)
            startProgressPolling()
        } catch (error: Exception) {
            output.delete()
            fail("VIDEO_COMPRESSION_FAILED", error.message ?: "Could not start Media3 export")
        }
    }

    private fun cancelCurrent() {
        val request = pendingRequest ?: return
        transformer?.cancel()
        emitProgress(0.0, "cancelled")
        val outputPath = request["outputPath"] as String
        File(outputPath).delete()
        complete(
            resultMap(
                terminal = "cancelled",
                request = request,
                elapsedMilliseconds = elapsedMilliseconds(),
            ),
        )
    }

    private fun resultMap(
        terminal: String,
        request: Map<String, Any?>,
        elapsedMilliseconds: Long,
    ): Map<String, Any?> {
        val inputPath = request["inputPath"] as String
        val outputPath = request["outputPath"] as String
        val requestedBitrate = (request["averageBitrate"] as Number).toInt()
        val appliedBitrate = (request["averageBitrateApplied"] as? Number)?.toInt() ?: requestedBitrate
        val warnings = mutableListOf(
            "Result records requested settings; route benchmark must ffprobe the output",
        )
        if (appliedBitrate < requestedBitrate) {
            warnings += "averageBitrate capped from $requestedBitrate to $appliedBitrate to stay below source bitrate"
        }
        return mapOf(
            "schemaVersion" to 1,
            "terminal" to terminal,
            "executor" to "android-media3-1.11.1-v0",
            "outputPath" to outputPath,
            "elapsedMilliseconds" to elapsedMilliseconds,
            "inputBytes" to File(inputPath).length(),
            "outputBytes" to File(outputPath).length(),
            "actualSettings" to mapOf(
                "codecRequested" to request["codec"],
                "averageBitrateRequested" to request["averageBitrate"],
                "averageBitrateApplied" to appliedBitrate,
                "audioRemoved" to request["removeAudio"],
                "hdrPolicyRequested" to request["hdrPolicy"],
                "input" to probeVideo(inputPath),
                "output" to probeVideo(outputPath),
            ),
            "warnings" to warnings,
        )
    }

    private fun adaptiveBitrate(
        requested: Int,
        inputPath: String,
        probe: Map<String, Any?>,
    ): Int {
        val ceilings = mutableListOf<Double>()
        (probe["estimatedDataRate"] as? Number)?.toDouble()?.takeIf { it > 0 }?.let {
            ceilings += it * 0.75
        }
        (probe["durationMilliseconds"] as? Number)?.toLong()?.takeIf { it > 0 }?.let { durationMs ->
            val totalRate = File(inputPath).length().toDouble() * 8_000.0 / durationMs
            ceilings += totalRate * 0.75
        }
        val ceiling = ceilings.minOrNull()?.takeIf { it.isFinite() && it > 0 } ?: return requested
        return minOf(requested, ceiling.toInt().coerceAtLeast(1))
    }

    internal fun plannedShortSide(cap: Int?, width: Int?, height: Int?): Int? {
        if (cap == null || width == null || height == null) return null
        if (minOf(width, height) <= cap) return null
        return cap - cap % 2
    }

    private fun sameFile(inputPath: String, outputPath: String): Boolean {
        if (File(inputPath).canonicalFile == File(outputPath).canonicalFile) return true
        val input = runCatching { Os.stat(inputPath) }.getOrNull() ?: return false
        val output = runCatching { Os.stat(outputPath) }.getOrNull() ?: return false
        return input.st_dev == output.st_dev && input.st_ino == output.st_ino
    }

    private fun elapsedMilliseconds(): Long = (System.nanoTime() - startedAtNanos) / 1_000_000

    // Media3 may silently tone-map unsupported HDR exports to SDR. Inspect
    // the source before starting Transformer so the default route can refuse
    // that color change and leave the original file untouched.
    private fun sourceHasHdrMetadata(path: String): Boolean? {
        val extractor = MediaExtractor()
        return try {
            extractor.setDataSource(path)
            var foundVideo = false
            var uncertain = false
            for (index in 0 until extractor.trackCount) {
                val format = extractor.getTrackFormat(index)
                val mime = format.getString(MediaFormat.KEY_MIME) ?: continue
                if (!mime.startsWith("video/")) continue
                foundVideo = true
                val transfer = if (format.containsKey(MediaFormat.KEY_COLOR_TRANSFER)) {
                    format.getInteger(MediaFormat.KEY_COLOR_TRANSFER)
                } else null
                val standard = if (format.containsKey(MediaFormat.KEY_COLOR_STANDARD)) {
                    format.getInteger(MediaFormat.KEY_COLOR_STANDARD)
                } else null
                val profile = if (format.containsKey(MediaFormat.KEY_PROFILE)) {
                    format.getInteger(MediaFormat.KEY_PROFILE)
                } else null
                if (mime.contains("dolby", ignoreCase = true) ||
                    transfer == MediaFormat.COLOR_TRANSFER_HLG ||
                    transfer == MediaFormat.COLOR_TRANSFER_ST2084 ||
                    standard == MediaFormat.COLOR_STANDARD_BT2020 ||
                    format.containsKey(MediaFormat.KEY_HDR_STATIC_INFO) ||
                    (mime == MimeTypes.VIDEO_H265 && profile == MediaCodecInfo.CodecProfileLevel.HEVCProfileMain10) ||
                    (mime == MimeTypes.VIDEO_H264 && profile == MediaCodecInfo.CodecProfileLevel.AVCProfileHigh10)
                ) return true
                // Untagged HEVC may still carry HDR information in the
                // bitstream, which the container probe cannot certify.
                if (mime == MimeTypes.VIDEO_H265 && transfer == null && standard == null) uncertain = true
            }
            if (!foundVideo || uncertain) null else false
        } catch (_: Exception) {
            null
        } finally {
            extractor.release()
        }
    }

    private fun probeVideo(path: String): Map<String, Any?> {
        if (!File(path).exists()) return emptyMap()
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(path)
            fun integer(key: Int): Int? = retriever.extractMetadata(key)?.toIntOrNull()
            fun decimal(key: Int): Double? = retriever.extractMetadata(key)?.toDoubleOrNull()

            val rawWidth = integer(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)
            val rawHeight = integer(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)
            val rotation = integer(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION) ?: 0
            val swapsDimensions = rotation == 90 || rotation == 270
            val mime = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_MIMETYPE)
            val codec = when (mime) {
                MimeTypes.VIDEO_H264 -> "h264"
                MimeTypes.VIDEO_H265 -> "hevc"
                else -> mime ?: "unknown"
            }
            mapOf(
                "codec" to codec,
                "width" to if (swapsDimensions) rawHeight else rawWidth,
                "height" to if (swapsDimensions) rawWidth else rawHeight,
                "nominalFrameRate" to decimal(MediaMetadataRetriever.METADATA_KEY_CAPTURE_FRAMERATE),
                "estimatedDataRate" to integer(MediaMetadataRetriever.METADATA_KEY_BITRATE),
                "durationMilliseconds" to integer(MediaMetadataRetriever.METADATA_KEY_DURATION),
                "rotation" to rotation,
            )
        } catch (_: Exception) {
            emptyMap()
        } finally {
            retriever.release()
        }
    }

    private fun startProgressPolling() {
        emitProgress(0.0, "encoding")
        val holder = ProgressHolder()
        val runnable = object : Runnable {
            override fun run() {
                val current = transformer ?: return
                val state = current.getProgress(holder)
                if (state == Transformer.PROGRESS_STATE_AVAILABLE) {
                    emitProgress(holder.progress / 100.0, "encoding")
                }
                if (transformer === current) mainHandler.postDelayed(this, 200)
            }
        }
        progressRunnable = runnable
        mainHandler.post(runnable)
    }

    private fun emitProgress(fraction: Double, stage: String) {
        progressSink?.success(
            mapOf(
                "fraction" to fraction.coerceIn(0.0, 1.0),
                "stage" to stage,
            ),
        )
    }

    @Synchronized
    private fun complete(value: Map<String, Any?>) {
        if (didComplete) return
        didComplete = true
        if (value["terminal"] == "succeeded") emitProgress(1.0, "finalizing")
        pendingResult?.success(value)
        clear()
    }

    @Synchronized
    private fun fail(code: String, message: String) {
        if (didComplete) return
        didComplete = true
        pendingResult?.error(code, message, null)
        clear()
    }

    private fun clear() {
        progressRunnable?.let(mainHandler::removeCallbacks)
        progressRunnable = null
        transformer = null
        pendingResult = null
        pendingRequest = null
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        cancelCurrent()
        channel.setMethodCallHandler(null)
        progressChannel.setStreamHandler(null)
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        progressSink = events
    }

    override fun onCancel(arguments: Any?) {
        progressSink = null
    }
}
