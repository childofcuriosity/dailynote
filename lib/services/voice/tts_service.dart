import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../secrets.dart';

/// Azure TTS speech synthesis, Xiaochen (Xiaochen) young female voice
/// Singleton: one shared player globally
/// Key is configured in secrets.dart (azureSpeechKey), not hardcoded
class TtsService {
  static final TtsService _instance = TtsService._();
  factory TtsService() => _instance;
  TtsService._();

  static const _region = 'eastasia';
  static const _voice = 'zh-CN-Xiaoyi:DragonHDFlashLatestNeural';

  final AudioPlayer _player = AudioPlayer();

  /// Speak text aloud (automatically cleans markdown)
  Future<void> speak(String text) async {
    final key = Secrets.azureSpeechKey;
    if (key.isEmpty) {
      debugPrint('Azure TTS: azureSpeechKey is not configured; skipping speech');
      return;
    }
    final cleaned = _stripMarkdown(text);
    if (cleaned.trim().isEmpty) return;

    try {
      final resp = await http.post(
        Uri.parse('https://$_region.tts.speech.microsoft.com/cognitiveservices/v1'),
        headers: {
          'Ocp-Apim-Subscription-Key': key,
          'Content-Type': 'application/ssml+xml',
          'X-Microsoft-OutputFormat': 'audio-24khz-160kbitrate-mono-mp3',
        },
        body: '''<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='zh-CN'>
  <voice name='$_voice'>$cleaned</voice>
</speak>''',
      );

      if (resp.statusCode == 200) {
        await _player.play(BytesSource(resp.bodyBytes));
      } else {
        debugPrint('Azure TTS error ${resp.statusCode}: ${resp.body}');
      }
    } catch (e) {
      debugPrint('Azure TTS error: $e');
    }
  }

  /// Stop speaking immediately
  Future<void> stop() async {
    await _player.stop();
  }

  /// Clean markdown/code blocks/formulas from AI replies into plain spoken text
  String _stripMarkdown(String text) {
    String t = text;

    t = t.replaceAll(RegExp(r'```[\s\S]*?```'), ', code omitted, ');
    t = t.replaceAll(RegExp(r'`([^`]+)`'), r'\1');
    t = t.replaceAll(RegExp(r'\[([^\]]+)\]\([^)]+\)'), r'\1');
    t = t.replaceAll(RegExp(r'\$\$[\s\S]*?\$\$'), ', formula omitted, ');
    t = t.replaceAll(RegExp(r'\$[^$]+\$'), ', formula omitted, ');
    t = t.replaceAll(RegExp(r'\*{1,3}'), '');
    t = t.replaceAll(RegExp(r'_{1,3}'), '');
    t = t.replaceAll(RegExp(r'~{1,2}'), '');
    t = t.replaceAll(RegExp(r'^#{1,6}\s+'), '');
    t = t.replaceAll(RegExp(r'^[-*+]\s+'), '');
    t = t.replaceAll(RegExp(r'^>\s+'), '');
    t = t.replaceAll(RegExp(r'^>\s?'), '');
    t = t.replaceAll(RegExp(r'\|'), ' ');
    t = t.replaceAll(RegExp(r'-{2,}'), '，');
    t = t.replaceAll(RegExp(r'\n{2,}'), '，');
    t = t.replaceAll(RegExp(r'\s+'), ' ');
    t = t.trim();

    return t;
  }
}
