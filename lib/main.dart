import 'package:flutter/material.dart';
import 'pages/home_page.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:audio_session/audio_session.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  initializeDateFormatting('zh_CN');

  // 配置音频会话：语音通信模式，支持蓝牙耳机
  final session = await AudioSession.instance;
  await session.configure(const AudioSessionConfiguration(
    avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
    avAudioSessionCategoryOptions: AVAudioSessionCategoryOptions.allowBluetooth,
    avAudioSessionMode: AVAudioSessionMode.voiceChat,
    androidAudioAttributes: const AndroidAudioAttributes(
      contentType: AndroidAudioContentType.speech,
      usage: AndroidAudioUsage.voiceCommunication,
    ),
    androidAudioFocusGainType: AndroidAudioFocusGainType.gain,
  ));

  runApp(const DailyNoteApp());
}

class DailyNoteApp extends StatelessWidget {
  const DailyNoteApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '日记助手',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}
