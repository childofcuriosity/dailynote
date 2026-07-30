import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:record/record.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'utils.dart';

/// VAD（Silero）检测语音边界 + SenseVoice 离线识别
/// 单例：模型（~230MB）全局只加载一次
class SttService {
  // ===== 单例 =====
  static final SttService _instance = SttService._();
  factory SttService() => _instance;
  SttService._();

  sherpa.OfflineRecognizer? _recognizer;
  sherpa.VoiceActivityDetector? _vad;
  sherpa.CircularBuffer? _buffer;
  static const _windowSize = 512; // Silero VAD 标准窗口大小（16kHz 下的固定值）
  final AudioRecorder _recorder = AudioRecorder();

  StreamSubscription<Uint8List>? _audioSub;
  bool _isListening = false;
  bool _ready = false;
  Future<void>? _initFuture; // 初始化进行中或已完成

  /// 初始化状态：null=未开始, true=完成, false=失败
  bool? get isInitialized => _initFuture == null ? null : _ready;

  static const _sampleRate = 16000;
  static const _modelDir = 'assets/models';

  // 累积所有识别到的文字
  final StringBuffer _accumulated = StringBuffer();

  void Function(String)? _onPartial;

  bool get isListening => _isListening;
  bool get isAvailable => _ready;

  // ========== 初始化（懒加载，只跑一次）==========

  /// 确保已初始化。首次调用时加载模型（~2秒），后续调用瞬间返回。
  Future<bool> ensureInitialized() async {
    if (_ready) return true;

    // 如果已经在初始化中，等它完成
    if (_initFuture != null) {
      await _initFuture;
      return _ready;
    }

    _initFuture = _doInit();
    await _initFuture;
    return _ready;
  }

  Future<void> _doInit() async {
    try {
      sherpa.initBindings();

      // Silero VAD
      final vadModelPath = await copyAssetFile('$_modelDir/silero_vad.onnx');
      final sileroConfig = sherpa.SileroVadModelConfig(
        model: vadModelPath,
        minSilenceDuration: 0.3,
        minSpeechDuration: 0.3,
        maxSpeechDuration: 10.0,
      );

      final vadConfig = sherpa.VadModelConfig(
        sileroVad: sileroConfig,
        numThreads: 1,
        debug: false,
      );

      _vad = sherpa.VoiceActivityDetector(
        config: vadConfig,
        bufferSizeInSeconds: 30,
      );
      _buffer = sherpa.CircularBuffer(capacity: 30 * _sampleRate);

      // SenseVoice
      final modelPath = await copyAssetFile('$_modelDir/model.int8.onnx');
      final tokensPath = await copyAssetFile('$_modelDir/tokens.txt');

      _recognizer = sherpa.OfflineRecognizer(sherpa.OfflineRecognizerConfig(
        model: sherpa.OfflineModelConfig(
          senseVoice: sherpa.OfflineSenseVoiceModelConfig(model: modelPath),
          tokens: tokensPath,
        ),
      ));

      _ready = true;
      debugPrint('SttService: VAD + SenseVoice 初始化成功');
    } catch (e) {
      _ready = false;
      debugPrint('SttService init error: $e');
    }
  }

  // ========== 开始 / 停止 ==========

  void startListening({
    required void Function(String text) onPartial,
    required void Function(String text) onDone,
    void Function(String error)? onError,
  }) {
    if (!_ready || _recognizer == null || _vad == null || _buffer == null) {
      return;
    }

    _onPartial = onPartial;
    _accumulated.clear();
    _isListening = true;

    _recorder.startStream(const RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: _sampleRate,
      numChannels: 1,
    )).then((audioStream) {
      _audioSub = audioStream.listen(
        _onAudioData,
        onError: (e) => onError?.call('$e'),
      );
    }).catchError((e) {
      _isListening = false;
      onError?.call('$e');
    });
  }

  void _onAudioData(Uint8List data) {
    if (_vad == null || _buffer == null || _recognizer == null) return;

    // PCM 16-bit → Float32
    // 注意：必须 Uint8List.fromList 确保 buffer offset 从 0 开始
    final samples = convertBytesToFloat32(Uint8List.fromList(data));

    // 写入环形缓冲区
    _buffer!.push(samples);

    // VAD 检测
    while (_buffer!.size > _windowSize) {
      final window = _buffer!.get(startIndex: _buffer!.head, n: _windowSize);
      _buffer!.pop(_windowSize);
      _vad!.acceptWaveform(window);

      // 处理检测到的语音段
      while (!_vad!.isEmpty()) {
        final segment = _vad!.front();

        // SenseVoice 识别这个语音段
        final stream = _recognizer!.createStream();
        stream.acceptWaveform(samples: segment.samples, sampleRate: _sampleRate);
        _recognizer!.decode(stream);
        final text = _recognizer!.getResult(stream).text;
        stream.free();

        _vad!.pop();

        // 累积文字
        if (text.isNotEmpty) {
          if (_accumulated.isNotEmpty) {
            _accumulated.write(' ');
          }
          _accumulated.write(text);
          _onPartial?.call(_accumulated.toString());
        }
      }
    }
  }

  /// 停止收音，flush VAD 剩余数据，返回累积的全部文字
  Future<String> stop() async {
    if (!_isListening) return '';
    _isListening = false;

    await _audioSub?.cancel();
    _audioSub = null;
    await _recorder.stop();

    // Flush VAD 中剩余的语音段
    _vad?.flush();
    while (_vad != null && !_vad!.isEmpty() && _recognizer != null) {
      final segment = _vad!.front();
      final stream = _recognizer!.createStream();
      stream.acceptWaveform(samples: segment.samples, sampleRate: _sampleRate);
      _recognizer!.decode(stream);
      final text = _recognizer!.getResult(stream).text;
      stream.free();
      _vad!.pop();

      if (text.isNotEmpty) {
        if (_accumulated.isNotEmpty) {
          _accumulated.write(' ');
        }
        _accumulated.write(text);
      }
    }

    final result = _accumulated.toString();
    _accumulated.clear();
    return result;
  }

  /// 取消，丢弃所有数据
  Future<void> cancel() async {
    _isListening = false;
    await _audioSub?.cancel();
    _audioSub = null;
    await _recorder.stop();
    _accumulated.clear();
  }
}
