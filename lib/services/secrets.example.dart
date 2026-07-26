/// 复制此文件为 secrets.dart，填入你的配置
/// secrets.dart 已在 .gitignore 中，不会被提交
class Secrets {
  // ===== AI API =====
  static const aiApiKey = 'sk-你的key';
  static const aiBaseUrl = 'https://api.deepseek.com/v1'; // 换成任何 OpenAI 兼容的 API 地址
  static const aiModel = 'deepseek-v4-pro';               // deepseek-chat / gpt-4o / moonshot-v1 等

  // ===== Supabase 云同步（可选，留空则不启用）=====
  static const supabaseUrl = '';  // 如 'https://xxx.supabase.co'
  static const supabaseAnonKey = '';

  // ===== 网页搜索（可选）=====
  static const serpapiApiKey = '';
}
