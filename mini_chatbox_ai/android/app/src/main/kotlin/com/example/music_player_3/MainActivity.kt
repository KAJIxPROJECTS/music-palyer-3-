package com.example.music_player_3

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.example.music_player_3/intent_handler"
    private var sharedAudioPath: String? = null
    private var methodChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        methodChannel?.setMethodCallHandler { call, result ->
            if (call.method == "getSharedAudioPath") {
                result.success(sharedAudioPath)
                sharedAudioPath = null
            } else {
                result.notImplemented()
            }
        }
    }

    companion object {
        init {
            try {
                System.loadLibrary("rust_audio_engine")
            } catch (e: Throwable) {
                android.util.Log.e("MainActivity", "Failed to load rust_audio_engine: ${e.message}")
            }
        }
    }

    private external fun initAndroid(context: android.content.Context)

    override fun onCreate(savedInstanceState: Bundle?) {
        try {
            initAndroid(applicationContext)
        } catch (e: Throwable) {
            android.util.Log.e("MainActivity", "Failed to initAndroid: ${e.message}")
        }
        super.onCreate(savedInstanceState)
        handleIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleIntent(intent)
        methodChannel?.invokeMethod("onSharedAudioReceived", sharedAudioPath)
    }

    private fun handleIntent(intent: Intent?) {
        if (intent == null) return
        if (intent.action == Intent.ACTION_VIEW || intent.action == Intent.ACTION_SEND) {
            val uri = if (intent.action == Intent.ACTION_SEND) {
                intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
            } else {
                intent.data
            }
            if (uri != null) {
                sharedAudioPath = copyUriToCache(uri)
            }
        }
    }

    private fun copyUriToCache(uri: Uri): String? {
        try {
            val contentResolver = contentResolver
            val fileName = "temp_shared_audio_" + System.currentTimeMillis() + ".mp3"
            val tempFile = File(cacheDir, fileName)
            contentResolver.openInputStream(uri).use { inputStream ->
                if (inputStream == null) return null
                FileOutputStream(tempFile).use { outputStream ->
                    val buffer = ByteArray(4096)
                    var bytesRead: Int
                    while (inputStream.read(buffer).also { bytesRead = it } != -1) {
                        outputStream.write(buffer, 0, bytesRead)
                    }
                }
            }
            return tempFile.absolutePath
        } catch (e: Exception) {
            return null
        }
    }
}
