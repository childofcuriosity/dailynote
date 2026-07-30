/// 解析 Supabase/VPS API 的时间字段（int 或 String 毫秒时间戳）
DateTime parseTime(dynamic v) {
  if (v is int) return DateTime.fromMillisecondsSinceEpoch(v);
  if (v is String) return DateTime.fromMillisecondsSinceEpoch(int.tryParse(v) ?? 0);
  return DateTime.now();
}
