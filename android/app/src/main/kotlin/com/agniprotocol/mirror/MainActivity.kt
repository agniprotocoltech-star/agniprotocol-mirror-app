package com.agniprotocol.mirror

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.Image
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Handler
import android.os.Looper
import android.util.DisplayMetrics
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.agniprotocol.mirror/screen"
    private val REQUEST_CODE = 1001
    private var methodChannel: MethodChannel? = null

    private var projectionManager: MediaProjectionManager? = null
    private var mediaProjection: MediaProjection? = null
    private var virtualDisplay: VirtualDisplay? = null
    private var imageReader: ImageReader? = null
    private val handler = Handler(Looper.getMainLooper())
    private var isCapturing = false

    private var screenWidth = 720
    private var screenHeight = 1280
    private var screenDensity = 1

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val metrics = DisplayMetrics()
        windowManager.defaultDisplay.getMetrics(metrics)
        screenWidth = metrics.widthPixels / 2  // Half size for bandwidth
        screenHeight = metrics.heightPixels / 2
        screenDensity = metrics.densityDpi

        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        methodChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "startCapture" -> {
                    projectionManager = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
                    startActivityForResult(projectionManager!!.createScreenCaptureIntent(), REQUEST_CODE)
                    result.success(null)
                }
                "stopCapture" -> {
                    stopCapture()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQUEST_CODE && resultCode == Activity.RESULT_OK && data != null) {
            mediaProjection = projectionManager?.getMediaProjection(resultCode, data)
            startCapture()
            methodChannel?.invokeMethod("onSharingStarted", null)
        }
    }

    private fun startCapture() {
        imageReader = ImageReader.newInstance(screenWidth, screenHeight, PixelFormat.RGBA_8888, 2)
        virtualDisplay = mediaProjection?.createVirtualDisplay(
            "AgniMirror", screenWidth, screenHeight, screenDensity,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
            imageReader!!.surface, null, null
        )
        isCapturing = true
        captureLoop()
    }

    private fun captureLoop() {
        handler.postDelayed(object : Runnable {
            override fun run() {
                if (!isCapturing) return
                try {
                    val image = imageReader?.acquireLatestImage()
                    if (image != null) {
                        val jpeg = imageToJpeg(image)
                        image.close()
                        if (jpeg != null) {
                            methodChannel?.invokeMethod("onFrame", jpeg.toList())
                        }
                    }
                } catch (e: Exception) {}
                if (isCapturing) handler.postDelayed(this, 100) // 10 FPS
            }
        }, 100)
    }

    private fun imageToJpeg(image: Image): ByteArray? {
        return try {
            val planes = image.planes
            val buffer = planes[0].buffer
            val pixelStride = planes[0].pixelStride
            val rowStride = planes[0].rowStride
            val rowPadding = rowStride - pixelStride * screenWidth

            val bitmap = Bitmap.createBitmap(
                screenWidth + rowPadding / pixelStride,
                screenHeight, Bitmap.Config.ARGB_8888
            )
            bitmap.copyPixelsFromBuffer(buffer)
            val cropped = Bitmap.createBitmap(bitmap, 0, 0, screenWidth, screenHeight)
            bitmap.recycle()

            val baos = ByteArrayOutputStream()
            cropped.compress(Bitmap.CompressFormat.JPEG, 50, baos)
            cropped.recycle()
            baos.toByteArray()
        } catch (e: Exception) { null }
    }

    private fun stopCapture() {
        isCapturing = false
        virtualDisplay?.release()
        imageReader?.close()
        mediaProjection?.stop()
        virtualDisplay = null
        imageReader = null
        mediaProjection = null
        methodChannel?.invokeMethod("onSharingStopped", null)
    }

    override fun onDestroy() {
        super.onDestroy()
        stopCapture()
    }
}
