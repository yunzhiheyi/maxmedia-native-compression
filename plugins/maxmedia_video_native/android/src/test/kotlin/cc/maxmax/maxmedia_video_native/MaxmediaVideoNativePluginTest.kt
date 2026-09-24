package cc.maxmax.maxmedia_video_native

import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/*
 * Unit tests for the method-channel contract of this plugin's Kotlin
 * implementation. capabilities() needs the Android MediaCodec registry and the
 * Transformer path needs a real context, so those are validated by the
 * route_lab app on devices; these tests pin dispatch and argument validation.
 */

internal class MaxmediaVideoNativePluginTest {
    private class RecordingResult : MethodChannel.Result {
        var successValue: Any? = null
        var succeeded = false
        var errorCode: String? = null
        var errorMessage: String? = null
        var notImplemented = false

        override fun success(value: Any?) {
            succeeded = true
            successValue = value
        }

        override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
            this.errorCode = errorCode
            this.errorMessage = errorMessage
        }

        override fun notImplemented() {
            notImplemented = true
        }
    }

    @Test
    fun onMethodCall_unknownMethod_reportsNotImplemented() {
        val plugin = MaxmediaVideoNativePlugin()
        val result = RecordingResult()

        plugin.onMethodCall(MethodCall("getPlatformVersion", null), result)

        assertTrue(result.notImplemented)
    }

    @Test
    fun onMethodCall_cancelWithoutPendingExport_succeeds() {
        val plugin = MaxmediaVideoNativePlugin()
        val result = RecordingResult()

        plugin.onMethodCall(MethodCall("cancel", null), result)

        assertTrue(result.succeeded)
        assertNull(result.successValue)
    }

    @Test
    fun onMethodCall_compressWithoutArguments_reportsInvalidArgument() {
        val plugin = MaxmediaVideoNativePlugin()
        val result = RecordingResult()

        plugin.onMethodCall(MethodCall("compress", null), result)

        assertEquals("INVALID_ARGUMENT", result.errorCode)
        assertEquals("Expected V1 request map", result.errorMessage)
    }

    @Test
    fun onMethodCall_compressWithNonMp4Container_reportsUnsupported() {
        val plugin = MaxmediaVideoNativePlugin()
        val result = RecordingResult()

        plugin.onMethodCall(
            MethodCall(
                "compress",
                mapOf(
                    "schemaVersion" to 1,
                    "inputPath" to "/in.mov",
                    "outputPath" to "/out.mov",
                    "container" to "mov",
                ),
            ),
            result,
        )

        assertEquals("UNSUPPORTED", result.errorCode)
        assertEquals("Media3 V0 only emits MP4", result.errorMessage)
    }

    @Test
    fun onMethodCall_compressWithExplicitDimensions_reportsUnsupported() {
        val plugin = MaxmediaVideoNativePlugin()
        val result = RecordingResult()

        plugin.onMethodCall(
            MethodCall(
                "compress",
                mapOf(
                    "schemaVersion" to 1,
                    "inputPath" to "/in.mov",
                    "outputPath" to "/out.mp4",
                    "container" to "mp4",
                    "width" to 720,
                    "height" to 1280,
                ),
            ),
            result,
        )

        assertEquals("UNSUPPORTED", result.errorCode)
        assertEquals("Use maxShortSide for scaling; frame rate changes are unsupported", result.errorMessage)
    }

    @Test
    fun shortSidePlanning_downscalesOnlyAndRoundsToEncoderSafeDimensions() {
        val plugin = MaxmediaVideoNativePlugin()

        assertEquals(720, plugin.plannedShortSide(720, 1080, 1920))
        assertEquals(720, plugin.plannedShortSide(720, 1920, 1080))
        assertEquals(718, plugin.plannedShortSide(719, 1080, 1920))
        assertNull(plugin.plannedShortSide(720, 720, 1280))
        assertNull(plugin.plannedShortSide(720, 480, 854))
        assertNull(plugin.plannedShortSide(null, 1080, 1920))
    }
}
