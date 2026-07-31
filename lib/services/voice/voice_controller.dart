import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'stt_service.dart';
import 'tts_service.dart';

/// 语音状态
enum VoiceState {
  idle,       // 空闲
  loading,    // 正在加载模型（首次）
  listening,  // 正在听
  processing, // 等 AI 回复
  speaking,   // 正在朗读
}

/// 协调 STT → API → TTS 的状态机
class VoiceController {
  final ValueNotifier<VoiceState> state = ValueNotifier(VoiceState.idle);

  /// 实时识别的部分文字，UI 显示「正在听：xxx」
  final ValueNotifier<String> partialText = ValueNotifier('');

  final SttService _stt = SttService();

  /// chat_page 注入：收识别文本 → 发后端 → 更新 UI → 返回 AI 回复文本
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
    // 进聊天页抢占音频优先权 + 保持屏幕常亮，防止息屏时酷狗抢走按键
    _headsetChannel.invokeMethod('refreshPriority');
    _headsetChannel.invokeMethod('keepScreenOn');
  }

  // ========== 按钮入口 ==========

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
        // barge-in：打断朗读，直接开始听新的
        await TtsService().stop();
        await _startListening();
    }
  }

  // ========== 内部流程 ==========

  Future<void> _startListening() async {
    // 权限检查
    var status = await Permission.microphone.status;
    if (!status.isGranted) {
      status = await Permission.microphone.request();
      if (!status.isGranted) {
        state.value = VoiceState.idle;
        return;
      }
    }

    // 懒加载模型（首次 ~2s，后续 0ms）
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
        debugPrint('VoiceController 录音错误: $error');
        state.value = VoiceState.idle;
        partialText.value = error;
      },
    );
  }

  /// 停止收音 → 有文字就发送，没文字回 idle
  Future<void> _stopAndSend() async {
    final text = await _stt.stop();
    // 录音结束刷新优先权，防止息屏时酷狗抢走下次按键
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
      // 网络错误等，静默回到 idle
    } finally {
      if (!_cancelled) {
        state.value = VoiceState.idle;
      }
    }
  }

  // ========== 控制 ==========

  void dispose() {
    _stt.cancel();
    TtsService().stop();
    _headsetChannel.invokeMethod('allowScreenOff');
    state.dispose();
    partialText.dispose();
  }
}
