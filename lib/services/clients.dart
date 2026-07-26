import 'package:supabase_flutter/supabase_flutter.dart';
import 'secrets.dart';

/// 全局 Supabase 客户端——跳过 SDK 初始化，直连 REST API
final supaClient = SupabaseClient(
  Secrets.supabaseUrl,
  Secrets.supabaseAnonKey,
);
