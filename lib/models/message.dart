import 'package:uuid/uuid.dart';

class Message {
  final int? id;
  final String uuid;
  final int? conversationId;
  final String? conversationUuid;
  final String role;
  final String content;
  final DateTime createdAt;
  final DateTime updatedAt;

  Message({
    this.id,
    String? uuid,
    this.conversationId,
    this.conversationUuid,
    required this.role,
    required this.content,
    required this.createdAt,
    DateTime? updatedAt,
  })  : uuid = uuid ?? const Uuid().v4(),
        updatedAt = updatedAt ?? DateTime.now();

  factory Message.fromMap(Map<String, dynamic> map) {
    return Message(
      id: map['id'] as int?,
      uuid: (map['uuid'] as String?) ?? const Uuid().v4(),
      conversationId: map['conversation_id'] as int?,
      conversationUuid: map['conversation_uuid'] as String?,
      role: map['role'] as String,
      content: map['content'] as String,
      createdAt: DateTime.fromMillisecondsSinceEpoch(map['created_at'] as int),
      updatedAt: map['updated_at'] != null
          ? DateTime.fromMillisecondsSinceEpoch(map['updated_at'] as int)
          : null,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      if (id != null) 'id': id,
      'uuid': uuid,
      'conversation_id': conversationId,
      'conversation_uuid': conversationUuid,
      'role': role,
      'content': content,
      'created_at': createdAt.millisecondsSinceEpoch,
      'updated_at': updatedAt.millisecondsSinceEpoch,
    };
  }

  /// 转为 Supabase 同步用的 map
  Map<String, dynamic> toSyncMap() {
    return {
      'id': uuid,
      'conversation_id': conversationUuid,
      'role': role,
      'content': content,
      'created_at': createdAt.millisecondsSinceEpoch,
      'updated_at': updatedAt.millisecondsSinceEpoch,
    };
  }

  factory Message.fromSyncMap(Map<String, dynamic> map) {
    return Message(
      uuid: map['id'] as String,
      conversationUuid: map['conversation_id'] as String?,
      role: map['role'] as String,
      content: map['content'] as String,
      createdAt: DateTime.fromMillisecondsSinceEpoch(map['created_at'] as int),
      updatedAt:
          DateTime.fromMillisecondsSinceEpoch(map['updated_at'] as int),
    );
  }
}
