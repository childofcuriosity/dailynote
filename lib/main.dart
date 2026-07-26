import 'package:flutter/material.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'pages/home_page.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'dart:io' show Platform;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }

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
