import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../secrets.dart';

/// Azure TTS 语音合成，Xiaochen（晓辰）少女音
/// 单例：全局共用一个播放器
/// Key 在 secrets.dart 中配置（azureSpeechKey），不硬编码
class TtsService {
  static final TtsService _instance = TtsService._();
  factory TtsService() => _instance;
  TtsService._();

  static const _region = 'eastasia';
  static const _voice = 'zh-CN-Xiaoyi:DragonHDFlashLatestNeural';

  final AudioPlayer _player = AudioPlayer();

  /// 念出文本（自动清洗 markdown）
  Future<void> speak(String text) async {
    final key = Secrets.azureSpeechKey;
    if (key.isEmpty) {
      debugPrint('Azure TTS: azureSpeechKey 未配置，跳过朗读');
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

  /// 立刻停止朗读
  Future<void> stop() async {
    await _player.stop();
  }

  /// 把 AI 回复里的 markdown/代码块/公式 清洗成纯口语文本
  String _stripMarkdown(String text) {
    String t = text;

    t = t.replaceAll(RegExp(r'```[\s\S]*?```'), '，代码省略，');
    t = t.replaceAll(RegExp(r'`([^`]+)`'), r'\1');
    t = t.replaceAll(RegExp(r'\[([^\]]+)\]\([^)]+\)'), r'\1');
    t = t.replaceAll(RegExp(r'\$\$[\s\S]*?\$\$'), '，公式省略，');
    t = t.replaceAll(RegExp(r'\$[^$]+\$'), '，公式省略，');
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
