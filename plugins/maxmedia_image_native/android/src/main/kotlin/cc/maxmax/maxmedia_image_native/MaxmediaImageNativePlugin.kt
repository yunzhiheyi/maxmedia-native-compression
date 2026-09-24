package cc.maxmax.maxmedia_image_native

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.ExifInterface
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.system.Os
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sqrt

class MaxmediaImageNativePlugin : FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private lateinit var channel: MethodChannel
    private lateinit var batchProgressChannel: EventChannel
    private var batchProgressSink: EventChannel.EventSink? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    // Parallel decodes of full-size bitmaps multiply peak memory; four workers
    // is the highest safe default on 256 MiB heap devices.
    private val executor = Executors.newFixedThreadPool(
        Runtime.getRuntime().availableProcessors().coerceIn(2, 4),
    )

    // Operations registered before their worker starts (so queued items can
    // be pulled with zero work) and removed as each settles.
    private val activeOperations: MutableSet<String> = ConcurrentHashMap.newKeySet()
    private val cancelledOperations: MutableSet<String> = ConcurrentHashMap.newKeySet()

    private fun cancelled(operationId: String?): Boolean =
        operationId != null && cancelledOperations.remove(operationId)

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "maxmedia_image_native")
        channel.setMethodCallHandler(this)
        batchProgressChannel = EventChannel(binding.binaryMessenger, "maxmedia_image_native/batch_progress")
        batchProgressChannel.setStreamHandler(this)
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        batchProgressSink = events
    }

    override fun onCancel(arguments: Any?) {
        batchProgressSink = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "capabilities" -> result.success(capabilities())
            "compress" -> {
                @Suppress("UNCHECKED_CAST")
                val arguments = call.arguments as? Map<String, Any?>
                if (arguments == null) {
                    result.error("INVALID_ARGUMENT", "Expected request map", null)
                    return
                }
                val operationId = arguments["operationId"] as? String
                if (operationId != null) activeOperations.add(operationId)
                executor.execute {
                    try {
                        val value = compress(arguments)
                        mainHandler.post { result.success(value) }
                    } catch (error: Exception) {
                        mainHandler.post {
                            result.error(
                                if (error is ColorPreservationException) "IMAGE_COLOR_PRESERVATION" else "IMAGE_COMPRESSION_FAILED",
                                error.message,
                                null,
                            )
                        }
                    } finally {
                        if (operationId != null) {
                            activeOperations.remove(operationId)
                            cancelledOperations.remove(operationId)
                        }
                    }
                }
            }
            "compressBatch" -> {
                @Suppress("UNCHECKED_CAST")
                val arguments = call.arguments as? Map<String, Any?>
                @Suppress("UNCHECKED_CAST")
                val requests = arguments?.get("requests") as? List<Map<String, Any?>>
                if (requests.isNullOrEmpty()) {
                    result.error("INVALID_ARGUMENT", "Expected a non-empty requests list", null)
                    return
                }
                val inputs = requests.mapNotNull { it["inputPath"] as? String }
                val outputs = requests.mapNotNull { it["outputPath"] as? String }
                if (inputs.size != requests.size || outputs.size != requests.size ||
                    outputs.indices.any { index ->
                        inputs.any { sameFile(it, outputs[index]) } ||
                            outputs.take(index).any { sameFile(it, outputs[index]) }
                    }) {
                    result.error("INVALID_ARGUMENT", "Batch outputs must not alias any input or another output", null)
                    return
                }
                val operationIds = requests.mapNotNull { it["operationId"] as? String }
                activeOperations.addAll(operationIds)
                val maxConcurrent =
                    (arguments["maxConcurrent"] as? Number)?.toInt() ?: 4
                compressBatch(requests, operationIds, arguments["batchId"] as? String, maxConcurrent, result)
            }
            "cancelImageCompression" -> {
                val arguments = call.arguments as? Map<String, Any?>
                val ids = (arguments?.get("operationIds") as? List<*>)?.filterIsInstance<String>()
                if (ids == null) {
                    cancelledOperations.addAll(activeOperations)
                } else {
                    cancelledOperations.addAll(ids.filter(activeOperations::contains))
                }
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun compressBatch(
        requests: List<Map<String, Any?>>,
        operationIds: List<String>,
        batchId: String?,
        maxConcurrent: Int,
        result: MethodChannel.Result,
    ) {
        val total = requests.size
        val completed = AtomicInteger(0)
        val outcomes = arrayOfNulls<Map<String, Any?>>(total)
        val pending = AtomicInteger(total)
        // Caller-configurable gate on top of the shared executor pool; the
        // effective concurrency is min(pool size, maxConcurrent).
        val gate = java.util.concurrent.Semaphore(maxConcurrent.coerceIn(1, 8))
        for (index in requests.indices) {
            executor.execute {
                val outcome: Map<String, Any?> = try {
                    gate.acquire()
                    try {
                        mapOf("index" to index, "result" to compress(requests[index]))
                    } finally {
                        gate.release()
                    }
                } catch (error: Exception) {
                    mapOf("index" to index, "error" to (error.message ?: "compression failed"))
                } finally {
                    operationIds.getOrNull(index)?.let { id ->
                        activeOperations.remove(id)
                        cancelledOperations.remove(id)
                    }
                }
                outcomes[index] = outcome
                val finished = completed.incrementAndGet()
                val terminal =
                    ((outcome["result"] as? Map<*, *>)?.get("terminal") as? String)
                        ?: "failed"
                mainHandler.post {
                    batchProgressSink?.success(
                        mapOf(
                            "batchId" to (batchId ?: ""),
                            "completed" to finished,
                            "total" to total,
                            "index" to index,
                            "terminal" to terminal,
                        ),
                    )
                }
                if (pending.decrementAndGet() == 0) {
                    mainHandler.post {
                        result.success(mapOf("results" to outcomes.toList()))
                    }
                }
            }
        }
    }

    private fun capabilities(): Map<String, Any> = mapOf(
        "schemaVersion" to 1,
        "executor" to "android-bitmap",
        "platform" to "android",
        "features" to listOf(
            "resize",
            "social-resize",
            "quality",
            "adaptive-quality-two-pass",
            "batch-compress",
            "cancel",
        ),
        "codecs" to emptyList<String>(),
        "formats" to listOf("jpeg", "png", "webp"),
        "warnings" to listOf(
            "Android Bitmap does not preserve source metadata",
            "PNG quality is ignored by the platform encoder",
        ),
    )

    @Suppress("DEPRECATION")
    private fun compress(arguments: Map<String, Any?>): Map<String, Any?> {
        require((arguments["schemaVersion"] as? Number)?.toInt() == 1) {
            "Unsupported request schema"
        }
        val inputPath = arguments["inputPath"] as? String ?: error("Missing inputPath")
        val outputPath = arguments["outputPath"] as? String ?: error("Missing outputPath")
        require(!sameFile(inputPath, outputPath)) { "Input and output must be different files" }
        val format = arguments["format"] as? String ?: error("Missing format")
        val quality = (arguments["quality"] as? Number)?.toDouble() ?: error("Missing quality")
        require(quality in 0.0..1.0) { "quality must be within 0..1" }
        require(format != "heic") { "HEIC encoding is not supported by android-bitmap route" }
        val colorPolicy = arguments["colorPolicy"] as? String ?: "keepOriginal"
        require(colorPolicy == "keepOriginal" || colorPolicy == "allowConversion") {
            "Unsupported colorPolicy: $colorPolicy"
        }
        val targetCompressionRatio = (arguments["targetCompressionRatio"] as? Number)?.toDouble()
        val minimumQuality = (arguments["minimumQuality"] as? Number)?.toDouble()
        require((targetCompressionRatio == null) == (minimumQuality == null)) {
            "targetCompressionRatio and minimumQuality must be supplied together"
        }
        if (targetCompressionRatio != null && minimumQuality != null) {
            require(targetCompressionRatio > 0.0 && targetCompressionRatio < 1.0) {
                "targetCompressionRatio must be within 0..1 (exclusive)"
            }
            require(minimumQuality in 0.0..quality) {
                "minimumQuality must be within 0..quality"
            }
        }

        val operationId = arguments["operationId"] as? String
        val startedAll = System.nanoTime()
        if (cancelled(operationId)) {
            return cancelledResult(outputPath, format, quality, startedAll)
        }

        val resizePolicy = arguments["resizePolicy"] as? String ?: "original"
        require(resizePolicy == "original" || resizePolicy == "social") {
            "Unsupported resizePolicy: $resizePolicy"
        }
        val orientation = readOrientation(inputPath)
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(inputPath, bounds)
        require(bounds.outWidth > 0 && bounds.outHeight > 0) {
            "Input image dimensions could not be read"
        }
        val inputColorSpace = if (Build.VERSION.SDK_INT >= 26) bounds.outColorSpace else null
        if (colorPolicy == "keepOriginal" && inputColorSpace == null) {
            throw ColorPreservationException(
                "Source image kept unchanged; this Android version or image decoder cannot verify its color space",
            )
        }
        val swapsAxes = orientationSwapsAxes(orientation)
        val inputWidth = if (swapsAxes) bounds.outHeight else bounds.outWidth
        val inputHeight = if (swapsAxes) bounds.outWidth else bounds.outHeight
        val socialTarget = if (resizePolicy == "social") {
            socialTarget(inputWidth, inputHeight)
        } else {
            null
        }
        val requestedMaxWidth = (arguments["maxWidth"] as? Number)?.toInt()
        val requestedMaxHeight = (arguments["maxHeight"] as? Number)?.toInt()
        val maxWidth = listOfNotNull(requestedMaxWidth, socialTarget?.first).minOrNull()
        val maxHeight = listOfNotNull(requestedMaxHeight, socialTarget?.second).minOrNull()
        val widthScale = maxWidth?.let { it.toDouble() / inputWidth } ?: 1.0
        val heightScale = maxHeight?.let { it.toDouble() / inputHeight } ?: 1.0
        val scale = min(1.0, min(widthScale, heightScale))
        val width = (inputWidth * scale).roundToInt().coerceAtLeast(1)
        val height = (inputHeight * scale).roundToInt().coerceAtLeast(1)
        val decodeTargetWidth = if (swapsAxes) height else width
        val decodeTargetHeight = if (swapsAxes) width else height
        val decodeOptions = BitmapFactory.Options().apply {
            inSampleSize = calculateInSampleSize(
                bounds.outWidth,
                bounds.outHeight,
                decodeTargetWidth,
                decodeTargetHeight,
            )
        }
        val decoded = BitmapFactory.decodeFile(inputPath, decodeOptions)
            ?: error("Input image could not be decoded")
        val input = normalizeOrientation(decoded, orientation)
        if (input !== decoded) decoded.recycle()
        val outputBitmap = if (width == inputWidth && height == inputHeight) {
            input
        } else {
            Bitmap.createScaledBitmap(input, width, height, true)
        }
        if (cancelled(operationId)) {
            if (outputBitmap !== input) outputBitmap.recycle()
            input.recycle()
            return cancelledResult(outputPath, format, quality, startedAll)
        }

        val compressFormat = when (format) {
            "jpeg" -> Bitmap.CompressFormat.JPEG
            "png" -> Bitmap.CompressFormat.PNG
            "webp" -> if (Build.VERSION.SDK_INT >= 30) {
                Bitmap.CompressFormat.WEBP_LOSSY
            } else {
                Bitmap.CompressFormat.WEBP
            }
            else -> error("Unsupported output format: $format")
        }
        val output = File(outputPath)
        output.parentFile?.mkdirs()
        val inputBytes = File(inputPath).length()
        val warnings = mutableListOf<String>()
        val isLossy = format == "jpeg" || format == "webp"
        var appliedQuality = quality
        var adaptiveAttempts = 1

        fun encode(encodeQuality: Double) {
            if (output.exists()) output.delete()
            FileOutputStream(output).use { stream ->
                check(
                    outputBitmap.compress(
                        compressFormat,
                        (encodeQuality * 100).roundToInt(),
                        stream,
                    ),
                ) { "Platform encoder failed" }
            }
        }

        val started = System.nanoTime()
        var outputBytes: Long
        try {
            encode(appliedQuality)
            outputBytes = output.length()
            // Abort between the two encodes: the finally block recycles both
            // bitmaps, so decoded pixel memory is freed before returning.
            if (cancelled(operationId)) {
                output.delete()
                return cancelledResult(outputPath, format, quality, startedAll)
            }
            if (
                isLossy &&
                targetCompressionRatio != null &&
                minimumQuality != null &&
                inputBytes > 0
            ) {
                val firstRatio = outputBytes.toDouble() / inputBytes
                if (firstRatio > targetCompressionRatio && quality > minimumQuality) {
                    val estimated = quality * targetCompressionRatio / firstRatio
                    val bounded = estimated.coerceIn(minimumQuality, quality)
                    val fallbackQuality = max(minimumQuality, (bounded * 100).roundToInt() / 100.0)
                    if (fallbackQuality < quality) {
                        appliedQuality = fallbackQuality
                        adaptiveAttempts = 2
                        encode(appliedQuality)
                        outputBytes = output.length()
                        warnings += "Image quality was adapted once while reusing the decoded pixels"
                    }
                }
                if (outputBytes.toDouble() / inputBytes > targetCompressionRatio) {
                    warnings += "The two-pass quality budget did not reach the target size reduction"
                }
            }
        } catch (error: Throwable) {
            output.delete()
            throw error
        } finally {
            if (outputBitmap !== input) outputBitmap.recycle()
            input.recycle()
        }
        val elapsedMilliseconds = (System.nanoTime() - started) / 1_000_000
        if (targetCompressionRatio != null && outputBytes >= inputBytes) {
            output.delete()
            error("Image compression produced no size reduction")
        }
        if (colorPolicy == "keepOriginal") {
            val outputBounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(outputPath, outputBounds)
            if (outputBounds.outColorSpace != inputColorSpace) {
                output.delete()
                throw ColorPreservationException(
                    "Source image kept unchanged; the output color space differs from the source",
                )
            }
        }

        if (arguments["preserveMetadata"] == true) {
            warnings += "Metadata was not preserved by android-bitmap"
        }
        if (format == "png") warnings += "PNG quality was ignored"
        if (resizePolicy == "social" && scale < 1.0) {
            warnings += "Social resize policy reduced pixel dimensions before encoding"
        }

        val actualSettings = mutableMapOf<String, Any?>(
            "format" to format,
            "quality" to appliedQuality,
            "qualityRequested" to quality,
            "qualityApplied" to appliedQuality,
            "adaptiveAttempts" to adaptiveAttempts,
            "totalElapsedMilliseconds" to (System.nanoTime() - startedAll) / 1_000_000,
            "inputWidth" to inputWidth,
            "inputHeight" to inputHeight,
            "width" to width,
            "height" to height,
            "metadataPreserved" to false,
            "colorPolicy" to colorPolicy,
            "orientationNormalized" to true,
            "resizePolicy" to resizePolicy,
            "socialResizeApplied" to (resizePolicy == "social" && scale < 1.0),
        )
        if (isLossy && targetCompressionRatio != null) {
            actualSettings["targetCompressionRatio"] = targetCompressionRatio
        }
        if (isLossy && minimumQuality != null) {
            actualSettings["minimumUsefulQuality"] = minimumQuality
        }

        return mapOf(
            "schemaVersion" to 1,
            "terminal" to "succeeded",
            "executor" to "android-bitmap",
            "outputPath" to outputPath,
            "elapsedMilliseconds" to elapsedMilliseconds,
            "inputBytes" to inputBytes,
            "outputBytes" to outputBytes,
            "actualSettings" to actualSettings,
            "warnings" to warnings,
        )
    }

    private fun cancelledResult(
        outputPath: String,
        format: String,
        quality: Double,
        startedNanos: Long,
    ): Map<String, Any?> = mapOf(
        "schemaVersion" to 1,
        "terminal" to "cancelled",
        "executor" to "android-bitmap",
        "outputPath" to outputPath,
        "elapsedMilliseconds" to (System.nanoTime() - startedNanos) / 1_000_000,
        "inputBytes" to 0L,
        "outputBytes" to 0L,
        "actualSettings" to mapOf(
            "format" to format,
            "qualityRequested" to quality,
            "cancelled" to true,
        ),
        "warnings" to listOf(
            "Compression was cancelled; decoded pixel memory was released immediately",
        ),
    )

    private fun readOrientation(inputPath: String): Int = try {
            ExifInterface(inputPath).getAttributeInt(
                ExifInterface.TAG_ORIENTATION,
                ExifInterface.ORIENTATION_NORMAL,
            )
        } catch (_: Exception) {
            ExifInterface.ORIENTATION_NORMAL
        }

    private fun sameFile(inputPath: String, outputPath: String): Boolean {
        if (File(inputPath).canonicalFile == File(outputPath).canonicalFile) return true
        val input = runCatching { Os.stat(inputPath) }.getOrNull() ?: return false
        val output = runCatching { Os.stat(outputPath) }.getOrNull() ?: return false
        return input.st_dev == output.st_dev && input.st_ino == output.st_ino
    }

    private fun orientationSwapsAxes(orientation: Int): Boolean = when (orientation) {
        ExifInterface.ORIENTATION_TRANSPOSE,
        ExifInterface.ORIENTATION_ROTATE_90,
        ExifInterface.ORIENTATION_TRANSVERSE,
        ExifInterface.ORIENTATION_ROTATE_270 -> true
        else -> false
    }

    private fun calculateInSampleSize(
        sourceWidth: Int,
        sourceHeight: Int,
        targetWidth: Int,
        targetHeight: Int,
    ): Int {
        var sampleSize = 1
        while (
            sourceWidth / (sampleSize * 2) >= targetWidth &&
            sourceHeight / (sampleSize * 2) >= targetHeight
        ) {
            sampleSize *= 2
        }
        return sampleSize
    }

    private fun normalizeOrientation(bitmap: Bitmap, orientation: Int): Bitmap {
        val matrix = Matrix()
        when (orientation) {
            ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> matrix.setScale(-1f, 1f)
            ExifInterface.ORIENTATION_ROTATE_180 -> matrix.setRotate(180f)
            ExifInterface.ORIENTATION_FLIP_VERTICAL -> {
                matrix.setRotate(180f)
                matrix.postScale(-1f, 1f)
            }
            ExifInterface.ORIENTATION_TRANSPOSE -> {
                matrix.setRotate(90f)
                matrix.postScale(-1f, 1f)
            }
            ExifInterface.ORIENTATION_ROTATE_90 -> matrix.setRotate(90f)
            ExifInterface.ORIENTATION_TRANSVERSE -> {
                matrix.setRotate(-90f)
                matrix.postScale(-1f, 1f)
            }
            ExifInterface.ORIENTATION_ROTATE_270 -> matrix.setRotate(-90f)
            else -> return bitmap
        }
        return Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
    }

    internal fun socialTarget(width: Int, height: Int): Pair<Int, Int> {
        // Policy adapted from Curzibn/flutter_luban (Apache-2.0), with the
        // never-upscale edge case kept strict for this plugin.
        val shortSide = min(width, height)
        val longSide = max(width, height)
        val ratio = shortSide.toDouble() / longSide
        val pixelCount = width.toLong() * height.toLong()
        var targetShort = 1440
        var targetLong = (targetShort / ratio).roundToInt()

        if (longSide >= 10_800 && ratio > 0.4) {
            targetLong = 1440
            targetShort = (targetLong * ratio).roundToInt()
        }
        if (pixelCount > 40_960_000L) {
            val trapShort = (shortSide * 0.25).roundToInt()
            if (trapShort < targetShort) {
                targetShort = trapShort
                targetLong = (targetShort / ratio).roundToInt()
            }
        }
        if (targetShort > shortSide) {
            targetShort = shortSide
            targetLong = longSide
        }
        val currentPixels = targetShort.toLong() * targetLong.toLong()
        if (currentPixels > 10_240_000L) {
            val capScale = floor(sqrt(10_240_000.0 / currentPixels) * 1000) / 1000
            targetShort = (targetShort * capScale).roundToInt()
            targetLong = (targetLong * capScale).roundToInt()
        }
        targetShort = max(1, targetShort / 2 * 2)
        targetLong = max(1, targetLong / 2 * 2)
        return if (width < height) {
            targetShort to targetLong
        } else {
            targetLong to targetShort
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        batchProgressChannel.setStreamHandler(null)
        batchProgressSink = null
        executor.shutdown()
    }
}

private class ColorPreservationException(message: String) : Exception(message)
