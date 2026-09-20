package com.umlive.voice

import android.content.Intent
import android.content.res.AssetManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileNotFoundException
import java.io.FileOutputStream
import java.security.MessageDigest
import java.util.concurrent.Executors

/**
 * Streams a bundled asset out of the APK into the app's own files directory.
 *
 * `sherpa_onnx` reads ordinary filesystem paths, so the 126 MB Spanish acoustic
 * model that ships inside the APK has to exist on disk before a recognizer can
 * be built. `rootBundle.load` would hold the whole file in the Dart heap;
 * `AssetManager` streams it 1 MiB at a time instead, so the provisioning peak is
 * one chunk plus the digest state -- independent of the model size.
 *
 * Channel `com.umlive.voice/assets`:
 *  - `copyAsset(path, destination)` -> `{ bytes, sha256, key, elapsedMs }`
 *  - progress is reported back on the same channel as `progress` with
 *    `{ path, copied, total }`, so the app can say how far along it is instead
 *    of showing an unexplained pause.
 *
 * A failed copy is reported as an error and never as a partial success: the Dart
 * side verifies the digest it receives here against the identity recorded by
 * `tool/fetch_sherpa_model.sh`.
 *
 * Channel `com.umlive.voice/service` (`T19`) is the drain window's boundary:
 *  - `start(title, body, count)` -> `{ ok: true }` or `{ ok: false, error }`
 *  - `update(title, body, count)` -> same
 *  - `stop()` -> same
 *
 * Each call forwards an action to [OutboxDrainService] and is answered with
 * those two fields, so the Dart side can log the outcome of its own request.
 * No failure is thrown across the channel: a platform that refuses to start the
 * service is a log line, not a broken conversation.
 */
class MainActivity : FlutterActivity() {
    private val worker = Executors.newSingleThreadExecutor()
    private var copying = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "copyAsset" -> copyAsset(
                    channel = channel,
                    path = call.argument<String>("path"),
                    destination = call.argument<String>("destination"),
                    result = result,
                )

                else -> result.notImplemented()
            }
        }
        configureServiceChannel(flutterEngine)
    }

    /**
     * The drain window's channel (`T19`), beside the assets channel and sharing
     * nothing with it.
     */
    private fun configureServiceChannel(flutterEngine: FlutterEngine) {
        val channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            SERVICE_CHANNEL,
        )
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> forwardToService(OutboxDrainService.ACTION_START, call, result)
                "update" -> forwardToService(OutboxDrainService.ACTION_UPDATE, call, result)
                "stop" -> forwardToService(OutboxDrainService.ACTION_STOP, call, result)
                else -> result.notImplemented()
            }
        }
    }

    /**
     * Turns one channel call into the service intent that carries it.
     *
     * The strings travel with the intent rather than being owned here: the
     * notification's copy is app copy, it lives in `app_es.arb`, and this side
     * of the boundary never invents a sentence.
     */
    private fun forwardToService(
        action: String,
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        // Non-null on purpose: the service refuses an empty copy anyway, and
        // this keeps the intent's extras plain values on the JVM side.
        val title = call.argument<String>("title") ?: ""
        val body = call.argument<String>("body") ?: ""
        val count = call.argument<Int>("count") ?: 0
        val intent = Intent(this, OutboxDrainService::class.java)
            .setAction(action)
            .putExtra(OutboxDrainService.EXTRA_TITLE, title)
            .putExtra(OutboxDrainService.EXTRA_BODY, body)
            .putExtra(OutboxDrainService.EXTRA_COUNT, count)
        try {
            when (action) {
                OutboxDrainService.ACTION_START -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        startForegroundService(intent)
                    } else {
                        startService(intent)
                    }
                }

                OutboxDrainService.ACTION_STOP -> {
                    try {
                        startService(intent)
                    } catch (_: IllegalStateException) {
                        // A backgrounded app may not start a service on API 26+,
                        // and a stop arrives exactly from there: the drain
                        // finished while the operator was not looking. Stopping
                        // the service through the platform is always allowed
                        // and reaches the same end -- the service dies and its
                        // notification goes with it.
                        stopService(Intent(this, OutboxDrainService::class.java))
                    }
                }

                else -> startService(intent)
            }
            result.success(mapOf("ok" to true))
        } catch (error: Throwable) {
            val detail = error.javaClass.simpleName
            result.success(mapOf("ok" to false, "error" to detail))
        }
    }

    override fun onDestroy() {
        worker.shutdown()
        super.onDestroy()
    }

    private fun copyAsset(
        channel: MethodChannel,
        path: String?,
        destination: String?,
        result: MethodChannel.Result,
    ) {
        if (path == null || destination == null) {
            result.error("badRequest", "path and destination are required", null)
            return
        }
        synchronized(this) {
            if (copying) {
                result.error("busy", "another asset copy is already running", null)
                return
            }
            copying = true
        }

        val assets = applicationContext.assets
        // Copying runs off the platform thread so a 126 MB stream never blocks
        // the UI; the result is delivered back on the platform thread, which is
        // where MethodChannel.Result has to be completed.
        worker.execute {
            try {
                val key = resolveKey(assets, path)
                val target = File(destination)
                target.parentFile?.mkdirs()

                val digest = MessageDigest.getInstance("SHA-256")
                val started = System.currentTimeMillis()
                var copied = 0L
                var reported = 0L
                val total = assetLength(assets, key)

                assets.open(key, AssetManager.ACCESS_STREAMING).use { input ->
                    FileOutputStream(target).use { output ->
                        val buffer = ByteArray(1 shl 20)
                        while (true) {
                            val read = input.read(buffer)
                            if (read <= 0) break
                            output.write(buffer, 0, read)
                            digest.update(buffer, 0, read)
                            copied += read
                            if (copied - reported >= PROGRESS_STEP || copied == total) {
                                reported = copied
                                reportProgress(channel, path, copied, total)
                            }
                        }
                        output.flush()
                    }
                }

                val answer = mapOf(
                    "bytes" to copied,
                    "sha256" to hex(digest.digest()),
                    "key" to key,
                    "elapsedMs" to (System.currentTimeMillis() - started),
                )
                runOnUiThread { result.success(answer) }
            } catch (error: FileNotFoundException) {
                runOnUiThread { result.error("assetMissing", error.message ?: "asset not found", null) }
            } catch (error: Throwable) {
                val detail = error.javaClass.simpleName + ": " + error.message
                runOnUiThread { result.error("copyFailed", detail, null) }
            } finally {
                synchronized(this) { copying = false }
            }
        }
    }

    /**
     * Flutter assets land in the APK under `assets/flutter_assets/`, but the
     * raw key is also tried so a future move of the model into
     * `android/app/src/main/assets/` needs no change here. The key that worked
     * is reported back, which is what makes that verifiable from `logcat`.
     */
    private fun resolveKey(assets: AssetManager, path: String): String {
        for (key in listOf("flutter_assets/$path", path)) {
            try {
                assets.open(key, AssetManager.ACCESS_STREAMING).close()
                return key
            } catch (_: FileNotFoundException) {
                // Try the next candidate key.
            }
        }
        throw FileNotFoundException("asset not found: $path")
    }

    private fun assetLength(assets: AssetManager, key: String): Long {
        return try {
            assets.openFd(key).use { it.length }
        } catch (_: Throwable) {
            // Compressed or otherwise not mapped: progress falls back to
            // unknown total, and the byte count on completion is still exact.
            -1L
        }
    }

    private fun reportProgress(channel: MethodChannel, path: String, copied: Long, total: Long) {
        runOnUiThread {
            channel.invokeMethod(
                "progress",
                mapOf("path" to path, "copied" to copied, "total" to total),
            )
        }
    }

    private fun hex(bytes: ByteArray): String {
        val out = StringBuilder(bytes.size * 2)
        for (byte in bytes) {
            out.append(HEX[(byte.toInt() shr 4) and 0x0f])
            out.append(HEX[byte.toInt() and 0x0f])
        }
        return out.toString()
    }

    private companion object {
        const val CHANNEL = "com.umlive.voice/assets"
        const val SERVICE_CHANNEL = "com.umlive.voice/service"
        const val PROGRESS_STEP = 8L * 1024 * 1024
        const val HEX = "0123456789abcdef"
    }
}
