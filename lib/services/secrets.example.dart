/// Copy this file to secrets.dart and fill in your configuration
/// secrets.dart is already in .gitignore and will not be committed
class Secrets {
  // ===== AI API =====
  static const aiApiKey = 'your-api-key';
  static const aiBaseUrl = 'https://api.deepseek.com/v1'; // Replace with any OpenAI-compatible API address
  static const aiModel = 'deepseek-v4-pro';               // deepseek-chat / gpt-4o / moonshot-v1, etc.

  // ===== VPS Agent service address (fill in public IP when phone connects to server; leave empty to use localhost) =====
  static const vpsBaseUrl = '';  // e.g. 'http://1.2.3.4:8081'

  // ===== Azure Speech (TTS, optional) =====
  static const azureSpeechKey = '';  // e.g. '9zRx...'

  // ===== Supabase cloud sync (optional, leave empty to disable) =====
  static const supabaseUrl = '';  // e.g. 'https://xxx.supabase.co'
  static const supabaseAnonKey = '';

  // ===== Web search (optional) =====
  static const serpapiApiKey = '';
}
