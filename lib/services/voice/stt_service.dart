import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:record/record.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'utils.dart';

/// VAD (Silero) detects speech boundaries + SenseVoice offline recognition
/// Singleton: the model (~230MB) is loaded only once globally
class SttService {
  // ===== Singleton =====
  static final SttService _instance = SttService._();
  factory SttService() => _instance;
  SttService._();

  sherpa.OfflineRecognizer? _recognizer;
  sherpa.VoiceActivityDetector? _vad;
  sherpa.CircularBuffer? _buffer;
  static const _windowSize = 512; // Silero VAD standard window size (fixed value at 16kHz)
  final AudioRecorder _recorder = AudioRecorder();

  StreamSubscription<Uint8List>? _audioSub;
  bool _isListening = false;
  bool _ready = false;
  Future<void>? _initFuture; // Initialization in progress or completed

  /// Initialization status: null=not started, true=completed, false=failed
  bool? get isInitialized => _initFuture == null ? null : _ready;

  static const _sampleRate = 16000;
  static const _modelDir = 'assets/models';

  // Accumulate all recognized text
  final StringBuffer _accumulated = StringBuffer();

  void Function(String)? _onPartial;

  bool get isListening => _isListening;
  bool get isAvailable => _ready;

  // ========== Initialization (lazy loading, runs only once) ==========

  /// Ensure initialized. Loads the model on first call (~2s); subsequent calls return instantly.
  Future<bool> ensureInitialized() async {
    if (_ready) return true;

    // If initialization is already in progress, wait for it to finish
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
      debugPrint('SttService: VAD + SenseVoice initialized');
    } catch (e) {
      _ready = false;
      debugPrint('SttService init error: $e');
    }
  }

  // ========== Start / Stop ==========

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
    // Note: Must use Uint8List.fromList to ensure buffer offset starts at 0
    final samples = convertBytesToFloat32(Uint8List.fromList(data));

    // Write to ring buffer
    _buffer!.push(samples);

    // VAD detection
    while (_buffer!.size > _windowSize) {
      final window = _buffer!.get(startIndex: _buffer!.head, n: _windowSize);
      _buffer!.pop(_windowSize);
      _vad!.acceptWaveform(window);

      // Process detected speech segments
      while (!_vad!.isEmpty()) {
        final segment = _vad!.front();

        // SenseVoice recognizes this speech segment
        final stream = _recognizer!.createStream();
        stream.acceptWaveform(samples: segment.samples, sampleRate: _sampleRate);
        _recognizer!.decode(stream);
        final text = _recognizer!.getResult(stream).text;
        stream.free();

        _vad!.pop();

        // Accumulate text
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

  /// Stop recording, flush remaining VAD data, return all accumulated text
  Future<String> stop() async {
    if (!_isListening) return '';
    _isListening = false;

    await _audioSub?.cancel();
    _audioSub = null;
    await _recorder.stop();

    // Flush remaining speech segments in VAD
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

  /// Cancel and discard all data
  Future<void> cancel() async {
    _isListening = false;
    await _audioSub?.cancel();
    _audioSub = null;
    await _recorder.stop();
    _accumulated.clear();
  }
}
