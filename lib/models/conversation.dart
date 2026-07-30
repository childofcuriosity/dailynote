import 'package:uuid/uuid.dart';

class Conversation {
  final String uuid;
  final String title;
  final String? summary;
  final String? userNote;
  final String? forkedFrom;
  final String source;
  final bool pinned;
  final bool hidden;
  final bool archived;
  final DateTime createdAt;
  final DateTime lastActiveAt;
  final DateTime? lastArchivedAt;
  final DateTime updatedAt;

  Conversation({
    String? uuid,
    required this.title,
    this.summary,
    this.userNote,
    this.forkedFrom,
    this.source = 'user',
    this.archived = false,
    this.pinned = false,
    this.hidden = false,
    required this.createdAt,
    DateTime? lastActiveAt,
    this.lastArchivedAt,
    DateTime? updatedAt,
  })  : uuid = uuid ?? const Uuid().v4(),
        lastActiveAt = lastActiveAt ?? createdAt,
        updatedAt = updatedAt ?? DateTime.now();

  bool get isDirty =>
      lastArchivedAt == null || lastActiveAt.isAfter(lastArchivedAt!);

  bool get isAiGenerated => source == 'explorer' || source == 'agent';

  factory Conversation.fromSupabase(Map<String, dynamic> map) {
    return Conversation(
      uuid: map['id'] as String,
      title: map['title'] as String,
      summary: map['summary'] as String?,
      userNote: map['user_note'] as String?,
      forkedFrom: map['forked_from'] as String?,
      source: map['source'] as String? ?? 'user',
      pinned: map['pinned'] == true,
      hidden: map['hidden'] == true,
      archived: map['archived'] == true,
      createdAt: _parseTime(map['created_at']),
      lastActiveAt: _parseTime(map['last_active_at']),
      lastArchivedAt: map['last_archived_at'] != null ? _parseTime(map['last_archived_at']) : null,
      updatedAt: _parseTime(map['updated_at']),
    );
  }

  Map<String, dynamic> toSupabase() {
    final now = DateTime.now().millisecondsSinceEpoch;
    return {
      'id': uuid,
      'title': title,
      'summary': summary,
      'user_note': userNote,
      'forked_from': forkedFrom,
      'pinned': pinned,
      'hidden': hidden,
      'created_at': createdAt.millisecondsSinceEpoch,
      'last_active_at': lastActiveAt.millisecondsSinceEpoch,
      'last_archived_at': lastArchivedAt?.millisecondsSinceEpoch,
      'updated_at': now,
    };
  }

  static DateTime _parseTime(dynamic v) {
    if (v is int) return DateTime.fromMillisecondsSinceEpoch(v);
    if (v is String) return DateTime.fromMillisecondsSinceEpoch(int.tryParse(v) ?? 0);
    return DateTime.now();
  }
}
