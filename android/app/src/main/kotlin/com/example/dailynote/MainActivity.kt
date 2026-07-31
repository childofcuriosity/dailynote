package com.example.dailynote

import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Handler
import android.os.Looper
import android.view.KeyEvent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var headsetChannel: MethodChannel? = null
    private var mediaSession: MediaSession? = null
    private val handler = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        headsetChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.dailynote.voice/headset"
        ).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "refreshPriority" -> refreshPriority()
                    "keepScreenOn" -> window.addFlags(
                        android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    "allowScreenOff" -> window.clearFlags(
                        android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                }
                result.success(null)
            }
        }
        setupMediaSession()
    }

    // ===== 刷新优先权（被酷狗抢走后夺回）=====

    private fun refreshPriority() {
        playSilence()
        mediaSession?.isActive = true
        mediaSession?.setPlaybackState(PlaybackState.Builder()
            .setActions(PlaybackState.ACTION_PLAY_PAUSE)
            .setState(PlaybackState.STATE_PLAYING,
                PlaybackState.PLAYBACK_POSITION_UNKNOWN, 1.0f)
            .build())
    }

    // ===== MediaSession（息屏时 dispatchKeyEvent 不工作，靠这个接按键）=====

    @Suppress("DEPRECATION")
    private fun setupMediaSession() {
        val channel = headsetChannel ?: return

        mediaSession = MediaSession(this, "DailyNote").apply {
            setCallback(object : MediaSession.Callback() {
                override fun onMediaButtonEvent(mediaButtonIntent: Intent): Boolean {
                    val keyEvent = mediaButtonIntent.getParcelableExtra<KeyEvent>(Intent.EXTRA_KEY_EVENT)
                    if (keyEvent != null && keyEvent.action == KeyEvent.ACTION_DOWN) {
                        when (keyEvent.keyCode) {
                            KeyEvent.KEYCODE_HEADSETHOOK,
                            KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE -> {
                                channel.invokeMethod("headsetButton", null)
                                return true
                            }
                        }
                    }
                    return super.onMediaButtonEvent(mediaButtonIntent)
                }
            })
            setPlaybackState(PlaybackState.Builder()
                .setActions(PlaybackState.ACTION_PLAY_PAUSE)
                .setState(PlaybackState.STATE_PLAYING,
                    PlaybackState.PLAYBACK_POSITION_UNKNOWN, 1.0f)
                .build())
            isActive = true
        }

        // 播一段无声音频 → 系统标记为"播放过音频的 App"
        // 息屏后按键分发优先给我们，不被酷狗抢
        playSilence()
    }

    private fun playSilence() {
        try {
            val bufSize = AudioTrack.getMinBufferSize(
                16000, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT)
            val track = AudioTrack.Builder()
                .setAudioAttributes(AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build())
                .setAudioFormat(AudioFormat.Builder()
                    .setSampleRate(16000)
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                    .build())
                .setBufferSizeInBytes(bufSize)
                .build()
            val silence = ShortArray(bufSize / 2)
            track.write(silence, 0, silence.size)
            track.play()
            // 100ms 后释放 — 足够系统标记为"播放过音频"
            handler.postDelayed({
                try { track.stop(); track.release() } catch (_: Exception) {}
            }, 100)
        } catch (_: Exception) {}
    }

    // ===== 亮屏时按键拦截 =====

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (event.action == KeyEvent.ACTION_DOWN) {
            when (event.keyCode) {
                KeyEvent.KEYCODE_HEADSETHOOK,
                KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE -> {
                    headsetChannel?.invokeMethod("headsetButton", null)
                    return true
                }
            }
        }
        return super.dispatchKeyEvent(event)
    }

    override fun onDestroy() {
        mediaSession?.release()
        mediaSession = null
        super.onDestroy()
    }
}
