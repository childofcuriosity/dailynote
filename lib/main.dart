import 'package:flutter/material.dart';
import 'pages/home_page.dart';
import 'package:intl/date_symbol_data_local.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  initializeDateFormatting('zh_CN');
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
