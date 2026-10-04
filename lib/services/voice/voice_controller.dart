import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'stt_service.dart';
import 'tts_service.dart';

/// Voice state
enum VoiceState {
  idle,       // Idle
  loading,    // Loading model (first time)
  listening,  // Listening
  processing, // Waiting for AI reply
  speaking,   // Speaking
}

/// State machine coordinating STT → API → TTS
class VoiceController {
  final ValueNotifier<VoiceState> state = ValueNotifier(VoiceState.idle);

  /// Partial text from real-time recognition, UI shows "Listening: xxx"
  final ValueNotifier<String> partialText = ValueNotifier('');

  final SttService _stt = SttService();

  /// chat_page injection: receive recognized text → send to backend → update UI → return AI reply text
  Future<String> Function(String text)? onVoiceSend;

  bool _cancelled = false;

  static const _headsetChannel = MethodChannel('com.dailynote.voice/headset');

  VoiceController() {
    _headsetChannel.setMethodCallHandler((call) {
      if (call.method == 'headsetButton') {
        toggle();
      }
      return Future<dynamic>.value();
    });
    // When entering chat page, seize audio priority + keep screen on, to prevent Kugou from taking over the button when the screen is off
    _headsetChannel.invokeMethod('refreshPriority');
    _headsetChannel.invokeMethod('keepScreenOn');
  }

  // ========== Button entry ==========

  Future<void> toggle() async {
    switch (state.value) {
      case VoiceState.idle:
      case VoiceState.loading:
        await _startListening();

      case VoiceState.listening:
        await _stopAndSend();

      case VoiceState.processing:
        _cancelled = true;
        state.value = VoiceState.idle;

      case VoiceState.speaking:
        // barge-in: interrupt speaking and start listening for new input directly
        await TtsService().stop();
        await _startListening();
    }
  }

  // ========== Internal flow ==========

  Future<void> _startListening() async {
    // Permission check
    var status = await Permission.microphone.status;
    if (!status.isGranted) {
      status = await Permission.microphone.request();
      if (!status.isGranted) {
        state.value = VoiceState.idle;
        return;
      }
    }

    // Lazy load model (first time ~2s, subsequent 0ms)
    if (!_stt.isAvailable) {
      state.value = VoiceState.loading;
      final ok = await _stt.ensureInitialized();
      if (!ok) {
        state.value = VoiceState.idle;
        return;
      }
    }

    partialText.value = '';
    state.value = VoiceState.listening;

    _stt.startListening(
      onPartial: (text) {
        partialText.value = text;
      },
      onDone: (_) {},
      onError: (error) {
        debugPrint('VoiceController recording error: $error');
        state.value = VoiceState.idle;
        partialText.value = error;
      },
    );
  }

  /// Stop capturing audio → if there is text, send it; if no text, return to idle
  Future<void> _stopAndSend() async {
    final text = await _stt.stop();
    // Refresh audio priority after recording ends, to prevent Kugou from taking over the next button press when the screen is off
    _headsetChannel.invokeMethod('refreshPriority');
    if (text.trim().isNotEmpty) {
      _onSpeechDone(text);
    } else {
      state.value = VoiceState.idle;
    }
  }

  Future<void> _onSpeechDone(String text) async {
    if (text.trim().isEmpty || onVoiceSend == null) {
      state.value = VoiceState.idle;
      return;
    }

    state.value = VoiceState.processing;
    _cancelled = false;

    try {
      final replyText = await onVoiceSend!(text.trim());
      if (_cancelled) return;

      if (replyText.isNotEmpty) {
        state.value = VoiceState.speaking;
        await TtsService().speak(replyText);
      }
    } catch (e) {
      // On network error etc., silently return to idle
    } finally {
      if (!_cancelled) {
        state.value = VoiceState.idle;
      }
    }
  }

  // ========== Control ==========

  void dispose() {
    _stt.cancel();
    TtsService().stop();
    _headsetChannel.invokeMethod('allowScreenOff');
    state.dispose();
    partialText.dispose();
  }
}
