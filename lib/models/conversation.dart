import 'package:uuid/uuid.dart';

class Conversation {
  final int? id;
  final String uuid;
  final String title;
  final String? summary;
  final String? userNote;
  final int? forkedFrom;
  final String? forkedFromUuid;
  final DateTime createdAt;
  final DateTime lastActiveAt;
  final DateTime? lastArchivedAt;
  final DateTime updatedAt;

  Conversation({
    this.id,
    String? uuid,
    required this.title,
    this.summary,
    this.userNote,
    this.forkedFrom,
    this.forkedFromUuid,
    required this.createdAt,
    DateTime? lastActiveAt,
    this.lastArchivedAt,
    DateTime? updatedAt,
  })  : uuid = uuid ?? const Uuid().v4(),
        lastActiveAt = lastActiveAt ?? createdAt,
        updatedAt = updatedAt ?? DateTime.now();

  bool get isDirty =>
      lastArchivedAt == null || lastActiveAt.isAfter(lastArchivedAt!);

  factory Conversation.fromMap(Map<String, dynamic> map) {
    return Conversation(
      id: map['id'] as int?,
      uuid: (map['uuid'] as String?) ?? const Uuid().v4(),
      title: map['title'] as String,
      summary: map['summary'] as String?,
      userNote: map['user_note'] as String?,
      forkedFrom: map['forked_from'] as int?,
      forkedFromUuid: map['forked_from_uuid'] as String?,
      createdAt: DateTime.fromMillisecondsSinceEpoch(map['created_at'] as int),
      lastActiveAt:
          DateTime.fromMillisecondsSinceEpoch(map['last_active_at'] as int),
      lastArchivedAt: map['last_archived_at'] != null
          ? DateTime.fromMillisecondsSinceEpoch(map['last_archived_at'] as int)
          : null,
      updatedAt: map['updated_at'] != null
          ? DateTime.fromMillisecondsSinceEpoch(map['updated_at'] as int)
          : null,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      if (id != null) 'id': id,
      'uuid': uuid,
      'title': title,
      'summary': summary,
      'user_note': userNote,
      'forked_from': forkedFrom,
      'forked_from_uuid': forkedFromUuid,
      'created_at': createdAt.millisecondsSinceEpoch,
      'last_active_at': lastActiveAt.millisecondsSinceEpoch,
      'last_archived_at': lastArchivedAt?.millisecondsSinceEpoch,
      'updated_at': updatedAt.millisecondsSinceEpoch,
    };
  }

  /// 转为 Supabase 同步用的 map（以 uuid 为主键，不含本地 id）
  Map<String, dynamic> toSyncMap() {
    return {
      'id': uuid,
      'title': title,
      'summary': summary,
      'user_note': userNote,
      'forked_from': forkedFromUuid,
      'created_at': createdAt.millisecondsSinceEpoch,
      'last_active_at': lastActiveAt.millisecondsSinceEpoch,
      'last_archived_at': lastArchivedAt?.millisecondsSinceEpoch,
      'updated_at': updatedAt.millisecondsSinceEpoch,
    };
  }

  factory Conversation.fromSyncMap(Map<String, dynamic> map) {
    return Conversation(
      uuid: map['id'] as String,
      title: map['title'] as String,
      summary: map['summary'] as String?,
      userNote: map['user_note'] as String?,
      forkedFromUuid: map['forked_from'] as String?,
      createdAt: DateTime.fromMillisecondsSinceEpoch(map['created_at'] as int),
      lastActiveAt:
          DateTime.fromMillisecondsSinceEpoch(map['last_active_at'] as int),
      lastArchivedAt: map['last_archived_at'] != null
          ? DateTime.fromMillisecondsSinceEpoch(map['last_archived_at'] as int)
          : null,
      updatedAt:
          DateTime.fromMillisecondsSinceEpoch(map['updated_at'] as int),
    );
  }
}
