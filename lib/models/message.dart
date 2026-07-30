import 'package:uuid/uuid.dart';
import '../services/utils.dart';

class Message {
  final String id;
  final String? conversationId;
  final String role;
  final String content;
  final String? reasoning;
  final DateTime createdAt;

  Message({
    String? id,
    this.conversationId,
    required this.role,
    required this.content,
    this.reasoning,
    required this.createdAt,
  }) : id = id ?? const Uuid().v4();

  factory Message.fromSupabase(Map<String, dynamic> map) {
    return Message(
      id: map['id'] as String,
      conversationId: map['conversation_id'] as String?,
      role: map['role'] as String,
      content: map['content'] as String,
      reasoning: map['reasoning'] as String?,
      createdAt: parseTime(map['created_at']),
    );
  }

  Map<String, dynamic> toSupabase() {
    return {
      'id': id,
      'conversation_id': conversationId,
      'role': role,
      'content': content,
      'reasoning': reasoning,
      'created_at': createdAt.millisecondsSinceEpoch,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    };
  }
}
