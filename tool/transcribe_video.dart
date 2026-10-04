import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

class TranscriptSegment {
  const TranscriptSegment({
    required this.start,
    required this.end,
    required this.text,
  });

  final double start;
  final double end;
  final String text;
}

String cleanText(String text) {
  return text
      .replaceAll(RegExp(r'<\|[^>]*\|>'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

String srtTime(double seconds) {
  final totalMs = math.max(0, (seconds * 1000).round());
  final hours = totalMs ~/ 3600000;
  final minutes = (totalMs % 3600000) ~/ 60000;
  final secs = (totalMs % 60000) ~/ 1000;
  final millis = totalMs % 1000;
  return '${hours.toString().padLeft(2, '0')}:'
      '${minutes.toString().padLeft(2, '0')}:'
      '${secs.toString().padLeft(2, '0')},'
      '${millis.toString().padLeft(3, '0')}';
}

int textLength(String text) => text.runes.length;

List<String> hardSplit(String text, int maxChars) {
  final runes = text.runes.toList();
  final result = <String>[];
  for (var start = 0; start < runes.length; start += maxChars) {
    final end = math.min(start + maxChars, runes.length);
    result.add(String.fromCharCodes(runes.sublist(start, end)));
  }
  return result;
}

List<String> splitCueText(String text, {int maxChars = 30}) {
  final clauses = RegExp(r'[^，。！？!?；;、,]+[，。！？!?；;、,]?')
      .allMatches(text)
      .map((match) => match.group(0)!.trim())
      .where((part) => part.isNotEmpty)
      .toList();

  final pieces = <String>[];
  for (final clause in clauses) {
    if (textLength(clause) <= maxChars) {
      pieces.add(clause);
    } else {
      pieces.addAll(hardSplit(clause, maxChars));
    }
  }

  final chunks = <String>[];
  var current = '';
  for (final piece in pieces) {
    if (current.isEmpty) {
      current = piece;
    } else if (textLength(current) + textLength(piece) <= maxChars) {
      current += piece;
    } else {
      chunks.add(current);
      current = piece;
    }
  }
  if (current.isNotEmpty) chunks.add(current);
  return chunks.isEmpty ? [text] : chunks;
}

String wrapCue(String text, {int lineChars = 17}) {
  if (textLength(text) <= lineChars) return text;
  final runes = text.runes.toList();
  final midpoint = runes.length ~/ 2;
  final candidates = <int>[];
  const punctuation = '，。！？!?；;、, ';
  for (var i = 0; i < runes.length; i++) {
    final position = i + 1;
    if (punctuation.contains(String.fromCharCode(runes[i])) &&
        position <= lineChars &&
        runes.length - position <= lineChars) {
      candidates.add(position);
    }
  }
  final split = candidates.isEmpty
      ? midpoint
      : candidates.reduce(
          (a, b) => (a - midpoint).abs() <= (b - midpoint).abs() ? a : b,
        );
  return '${String.fromCharCodes(runes.sublist(0, split)).trim()}\n'
      '${String.fromCharCodes(runes.sublist(split)).trim()}';
}

String buildSrt(List<TranscriptSegment> segments) {
  final output = StringBuffer();
  var cueIndex = 0;

  for (final segment in segments) {
    final chunks = splitCueText(segment.text);
    final totalWeight = chunks.fold<int>(
      0,
      (sum, chunk) => sum + textLength(chunk),
    );
    var cursor = segment.start;

    for (var i = 0; i < chunks.length; i++) {
      final cueEnd = i == chunks.length - 1
          ? segment.end
          : cursor +
                (segment.end - segment.start) *
                    textLength(chunks[i]) /
                    totalWeight;
      cueIndex += 1;
      output
        ..writeln(cueIndex)
        ..writeln('${srtTime(cursor)} --> ${srtTime(cueEnd)}')
        ..writeln(wrapCue(chunks[i]))
        ..writeln();
      cursor = cueEnd;
    }
  }
  return output.toString();
}

void main(List<String> args) {
  if (args.length != 7) {
    stderr.writeln(
      'Usage: dart transcribe_video.dart WAV MODEL TOKENS VAD DLL_DIR SRT TXT',
    );
    exitCode = 64;
    return;
  }

  final wavPath = args[0];
  final modelPath = args[1];
  final tokensPath = args[2];
  final vadPath = args[3];
  final dllDirectory = args[4];
  final srtPath = args[5];
  final txtPath = args[6];

  final nativeLibraries = <DynamicLibrary>[];
  for (final name in ['onnxruntime.dll', 'onnxruntime_providers_shared.dll']) {
    final path = '$dllDirectory\\$name';
    if (File(path).existsSync()) {
      nativeLibraries.add(DynamicLibrary.open(path));
    }
  }
  sherpa.initBindings(dllDirectory);

  stderr.writeln('Reading audio...');
  final wave = sherpa.readWave(wavPath);
  if (wave.samples.isEmpty || wave.sampleRate != 16000) {
    throw StateError('Expected a nonempty 16 kHz WAV; received ${wave.sampleRate} Hz: $wavPath');
  }

  final vad = sherpa.VoiceActivityDetector(
    config: sherpa.VadModelConfig(
      sileroVad: sherpa.SileroVadModelConfig(
        model: vadPath,
        threshold: 0.45,
        minSilenceDuration: 0.45,
        minSpeechDuration: 0.20,
        maxSpeechDuration: 12.0,
      ),
      sampleRate: wave.sampleRate,
      numThreads: 1,
      debug: false,
    ),
    bufferSizeInSeconds: 30,
  );

  stderr.writeln('Loading the SenseVoice model...');
  final recognizer = sherpa.OfflineRecognizer(
    sherpa.OfflineRecognizerConfig(
      model: sherpa.OfflineModelConfig(
        senseVoice: sherpa.OfflineSenseVoiceModelConfig(
          model: modelPath,
          useInverseTextNormalization: true,
        ),
        tokens: tokensPath,
        numThreads: 4,
        debug: false,
      ),
    ),
  );

  final segments = <TranscriptSegment>[];

  void drainSegments() {
    while (!vad.isEmpty()) {
      final speech = vad.front();
      vad.pop();
      if (speech.samples.isEmpty) continue;

      final stream = recognizer.createStream();
      try {
        stream.acceptWaveform(
          samples: speech.samples,
          sampleRate: wave.sampleRate,
        );
        recognizer.decode(stream);
        final text = cleanText(recognizer.getResult(stream).text);
        if (text.isEmpty) continue;

        final start = speech.start / wave.sampleRate;
        final end = start + speech.samples.length / wave.sampleRate;
        segments.add(TranscriptSegment(start: start, end: end, text: text));
        stderr.writeln(
          '${segments.length.toString().padLeft(3)}  '
          '${srtTime(start)}  $text',
        );
      } finally {
        stream.free();
      }
    }
  }

  try {
    const chunkSize = 512;
    for (var offset = 0; offset < wave.samples.length; offset += chunkSize) {
      final end = math.min(offset + chunkSize, wave.samples.length);
      vad.acceptWaveform(Float32List.sublistView(wave.samples, offset, end));
      drainSegments();
    }
    vad.flush();
    drainSegments();

    if (segments.isEmpty) {
      throw StateError('No recognizable speech detected.');
    }

    File(srtPath).writeAsStringSync(buildSrt(segments));
    File(txtPath).writeAsStringSync(
      '${segments.map((segment) => segment.text).join('\n')}\n',
    );
    stderr.writeln('Transcription complete: ${segments.length} speech segments.');
  } finally {
    recognizer.free();
    vad.free();
    if (nativeLibraries.isEmpty) {
      stderr.writeln('Warning: ONNX Runtime dependencies were not preloaded.');
    }
  }
}
