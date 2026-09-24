package cc.maxmax.maxmedia_image_native

import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/*
 * Unit tests for the method-channel contract of this plugin's Kotlin
 * implementation. The compress decode/encode path needs Android framework
 * graphics classes, so it is exercised by the route_lab app on real devices;
 * these tests pin the capabilities payload and argument validation.
 */

internal class MaxmediaImageNativePluginTest {
    private class RecordingResult : MethodChannel.Result {
        var successValue: Any? = null
        var succeeded = false
        var errorCode: String? = null
        var errorMessage: String? = null
        var errorDetails: Any? = null
        var notImplemented = false

        override fun success(value: Any?) {
            succeeded = true
            successValue = value
        }

        override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
            this.errorCode = errorCode
            this.errorMessage = errorMessage
            this.errorDetails = errorDetails
        }

        override fun notImplemented() {
            notImplemented = true
        }
    }

    @Test
    fun onMethodCall_capabilities_reportsAdaptiveTwoPassSupport() {
        val plugin = MaxmediaImageNativePlugin()
        val result = RecordingResult()

        plugin.onMethodCall(MethodCall("capabilities", null), result)

        assertTrue(result.succeeded)
        val capabilities = result.successValue as Map<*, *>
        assertEquals(1, capabilities["schemaVersion"])
        val features = capabilities["features"] as List<*>
        assertTrue(features.contains("adaptive-quality-two-pass"))
        assertTrue(features.contains("batch-compress"))
        val formats = capabilities["formats"] as List<*>
        assertTrue(formats.containsAll(listOf("jpeg", "png", "webp")))
    }

    @Test
    fun onMethodCall_compressWithoutArguments_reportsInvalidArgument() {
        val plugin = MaxmediaImageNativePlugin()
        val result = RecordingResult()

        plugin.onMethodCall(MethodCall("compress", null), result)

        assertEquals("INVALID_ARGUMENT", result.errorCode)
        assertEquals("Expected request map", result.errorMessage)
        assertNull(result.errorDetails)
    }

    @Test
    fun onMethodCall_compressBatchWithoutRequests_reportsInvalidArgument() {
        val plugin = MaxmediaImageNativePlugin()
        val result = RecordingResult()

        plugin.onMethodCall(MethodCall("compressBatch", null), result)

        assertEquals("INVALID_ARGUMENT", result.errorCode)
        assertEquals("Expected a non-empty requests list", result.errorMessage)
    }

    @Test
    fun onMethodCall_compressBatchWithEmptyList_reportsInvalidArgument() {
        val plugin = MaxmediaImageNativePlugin()
        val result = RecordingResult()

        plugin.onMethodCall(
            MethodCall("compressBatch", mapOf<String, Any>("requests" to emptyList<Map<String, Any>>())),
            result,
        )

        assertEquals("INVALID_ARGUMENT", result.errorCode)
    }

    @Test
    fun onMethodCall_compressBatchCrossAlias_reportsInvalidArgument() {
        val plugin = MaxmediaImageNativePlugin()
        val result = RecordingResult()
        val requests = listOf(
            mapOf("inputPath" to "/tmp/first.jpg", "outputPath" to "/tmp/second.jpg"),
            mapOf("inputPath" to "/tmp/second.jpg", "outputPath" to "/tmp/other.webp"),
        )

        plugin.onMethodCall(MethodCall("compressBatch", mapOf("requests" to requests)), result)

        assertEquals("INVALID_ARGUMENT", result.errorCode)
    }

    @Test
    fun onMethodCall_unknownMethod_reportsNotImplemented() {
        val plugin = MaxmediaImageNativePlugin()
        val result = RecordingResult()

        plugin.onMethodCall(MethodCall("getPlatformVersion", null), result)

        assertTrue(result.notImplemented)
    }

    @Test
    fun socialTarget_neverUpscalesAndKeepsEvenSides() {
        val plugin = MaxmediaImageNativePlugin()

        val small = plugin.socialTarget(800, 600)
        assertEquals(800, small.first)
        assertEquals(600, small.second)

        val landscape = plugin.socialTarget(4032, 3024)
        assertEquals(1920, landscape.first)
        assertEquals(1440, landscape.second)
        assertEquals(0, landscape.first % 2)
        assertEquals(0, landscape.second % 2)

        val portrait = plugin.socialTarget(3024, 4032)
        assertEquals(1440, portrait.first)
        assertEquals(1920, portrait.second)
    }
}
