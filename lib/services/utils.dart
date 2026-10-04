/// Parse the time field of Supabase/VPS API (int or String millisecond timestamp)
DateTime parseTime(dynamic v) {
  if (v is int) return DateTime.fromMillisecondsSinceEpoch(v);
  if (v is String) return DateTime.fromMillisecondsSinceEpoch(int.tryParse(v) ?? 0);
  return DateTime.now();
}
