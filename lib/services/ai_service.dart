import 'dart:convert';
import 'package:http/http.dart' as http;

class ToolCall {
  final String id;
  final String name;
  final Map<String, dynamic> arguments;

  ToolCall({required this.id, required this.name, required this.arguments});

  factory ToolCall.fromMap(Map<String, dynamic> map) {
    return ToolCall(
      id: map['id'] as String,
      name: map['function']['name'] as String,
      arguments: jsonDecode(map['function']['arguments'] as String),
    );
  }
}

class ChatResponse {
  final String? content;
  final String? reasoningContent;
  final List<ToolCall>? toolCalls;

  ChatResponse({this.content, this.reasoningContent, this.toolCalls});

  bool get isToolCalls => toolCalls != null && toolCalls!.isNotEmpty;
}

class AiService {
  final String baseUrl;
  final String model;
  final String apiKey;

  /// [baseUrl] — API 地址，默认 DeepSeek。换成 OpenAI 兼容的其他服务即可切换
  /// [model] — 模型名
  AiService({
    required this.apiKey,
    this.baseUrl = 'https://api.deepseek.com/v1',
    this.model = 'deepseek-v4-pro',
  });

  /// 构建 messages 列表（支持 system / user / assistant / tool）
  List<Map<String, dynamic>> buildMessages({
    required String systemPrompt,
    String? memoryContext,
    String? ragContext,
    String? dateNote,
    required List<Map<String, dynamic>> conversation,
  }) {
    final messages = <Map<String, dynamic>>[];

    var systemContent = systemPrompt;
    if (dateNote != null) {
      systemContent += '\n\n[日期信息]\n$dateNote';
    }
    if (memoryContext != null) {
      systemContent += '\n\n[关于用户的记忆]\n$memoryContext';
    }
    messages.add({'role': 'system', 'content': systemContent});

    if (ragContext != null) {
      messages.add({
        'role': 'user',
        'content': '[系统检索到的相关历史]\n$ragContext',
      });
    }

    messages.addAll(conversation);
    return messages;
  }

  /// 发送请求，支持 tools。返回 ChatResponse
  Future<ChatResponse> sendRequest({
    required List<Map<String, dynamic>> messages,
    required double temperature,
    List<Map<String, dynamic>>? tools,
  }) async {
    final body = <String, dynamic>{
      'model': model,
      'messages': messages,
      'temperature': temperature,
    };
    if (tools != null && tools.isNotEmpty) {
      body['tools'] = tools;
    }

    final response = await http.post(
      Uri.parse('$baseUrl/chat/completions'),
      headers: {
        'Authorization': 'Bearer $apiKey',
        'Content-Type': 'application/json',
      },
      body: jsonEncode(body),
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      final choice = data['choices'][0];
      final msg = choice['message'];

      if (msg['tool_calls'] != null) {
        final List<dynamic> tcs = msg['tool_calls'];
        return ChatResponse(
          toolCalls: tcs.map((t) => ToolCall.fromMap(t)).toList(),
        );
      }

      return ChatResponse(
        content: msg['content'] as String? ?? '',
        reasoningContent: msg['reasoning_content'] as String?,
      );
    } else {
      throw Exception(
          'API 错误 (${response.statusCode}): ${response.body}');
    }
  }

  /// 归档分析 —— 接收用户可选指令，支持拆分
  Future<Map<String, dynamic>> archiveConversation({
    required List<Map<String, dynamic>> messages,
    String? userInstruction,
    List<String>? existingMemories,
    List<String>? tagLibrary,
  }) async {
    final instructionPart = userInstruction != null && userInstruction.isNotEmpty
        ? '\n用户的归档要求：$userInstruction'
        : '';

    final existingPart = existingMemories != null && existingMemories.isNotEmpty
        ? '\n已有的长期记忆：\n${existingMemories.asMap().entries.map((e) => "${e.key + 1}. ${e.value}").join("\n")}\n\n这些是之前归档时提取的记忆。如果新事实和已有记忆是同一件事，不要重复输出。如果新信息更具体准确，旧的事实会保留，所以不要写重复或只是措辞不同的同一条事实。'
        : '';

    final tagLib = tagLibrary != null && tagLibrary.isNotEmpty
        ? '\n现有标签：${tagLibrary.join("、")}。优先从现有标签中选，如果没有合适的可以返回新标签名。'
        : '';

    final archivePrompt = '''你是一个日记归档助手。这是用户主动触发的归档，分析以下对话，返回 JSON。

$instructionPart
$tagLib
$existingPart
按话题切换点切分对话，不同话题分成不同的段。2-5段为宜。

返回格式（严格 JSON，不要其他文字）：
{
  "segments": [
    {
      "title": "段落标题（15字以内）",
      "tags": ["标签1", "标签2"],
      "summary": "一段话总结信息量内容，去掉寒暄和废话，保留事实、决定、进展、情绪要点",
      "memories": ["可跨会话检索的原子事实1"],
      "startIndex": 0,
      "endIndex": 4
    }
  ]
}

规则：
- tags 给每段打1-3个标签。优先选现有标签，没有合适的就创建新标签（返回新名字）
- 内容确实没有合适标签时 tags 可以是空数组 []
- 每条消息都要归属于某一段，不要遗漏，不要重叠
- 如果整段对话只有一个话题，就返回一段
- 如果用户有拆分要求，优先听用户的
- summary 只保留有信息价值的内容，不说"用户和助手聊了xx"这种废话
- memories 每一条是独立原子事实''';

    final allMessages = buildMessages(
      systemPrompt: archivePrompt,
      conversation: messages,
    );

    final response = await sendRequest(
      messages: allMessages,
      temperature: 0.2,
    );

    var jsonStr = (response.content ?? '').trim();
    if (jsonStr.startsWith('```')) {
      jsonStr = jsonStr.replaceFirst(RegExp(r'```\w*\n?'), '');
      jsonStr = jsonStr.replaceFirst('```', '');
    }
    jsonStr = jsonStr.trim();

    return jsonDecode(jsonStr) as Map<String, dynamic>;
  }

  /// 自动兜底归档 —— 不拆分话题，静默处理
  Future<Map<String, dynamic>> autoArchive({
    required List<Map<String, dynamic>> messages,
    String? existingSummary,
    List<String>? existingMemories,
  }) async {
    final existingNote = existingSummary != null
        ? '\n之前的摘要：$existingSummary'
        : '';

    final memoriesPart = existingMemories != null && existingMemories.isNotEmpty
        ? '\n已有的长期记忆（不要输出重复的，除非有更新）：\n${existingMemories.asMap().entries.map((e) => "${e.key + 1}. ${e.value}").join("\n")}'
        : '';

    final prompt = '''你是日记归档助手。这是一段自动归档，不需要用户干预。

$existingNote

$memoriesPart
重要：这段对话视为一个整体话题，不要拆分。只返回一段。

返回严格 JSON：
{
  "title": "会话标题（15字以内）",
  "tags": ["标签1"],
  "summary": "一段话总结信息量内容，去掉寒暄和废话",
  "memories": ["原子事实1", "事实2"]
}''';

    final allMessages = buildMessages(
      systemPrompt: prompt,
      conversation: messages,
    );

    final response = await sendRequest(
      messages: allMessages,
      temperature: 0.2,
    );

    var jsonStr = (response.content ?? '').trim();
    if (jsonStr.startsWith('```')) {
      jsonStr = jsonStr.replaceFirst(RegExp(r'```\w*\n?'), '');
      jsonStr = jsonStr.replaceFirst('```', '');
    }
    jsonStr = jsonStr.trim();

    return jsonDecode(jsonStr) as Map<String, dynamic>;
  }
}
