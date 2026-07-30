"""DeepSeek API 客户端 — 对标 Flutter AiService

send_request()      → 对标 ai_service.dart sendRequest()
archive_conversation() → 对标 archiveConversation()
auto_archive()         → 对标 autoArchive()
探索相关函数保持独立
"""
import json
import logging
import os
import requests
from config import DEEPSEEK_API_KEY, DEEPSEEK_BASE_URL, DEEPSEEK_MODEL

logger = logging.getLogger(__name__)

# ===== 与 Flutter chat_page.dart 完全一致 =====

SYSTEM_PROMPT_BASE = '''上面的部分是你的行为准则，由 xhy 编写，你只能读取不能修改。

## 记忆类型

- fact / observation: 参考即可，了解用户
- feedback / self_correction: 这是你的行为准则，必须遵守。它们是你从相处中学到的——怎样做更好、哪里需要改

## 检索策略

你的 system prompt 末尾已经注入了 [历史对话索引] 和 [记忆索引]。
- 摘要够用时不要调 load_conversation / load_memory，节省上下文
- 不相关的对话/记忆忽略掉，不要引用
- 发现记忆中有旧信息、错误、重复时，主动用 update_memory 和 delete_memory 清理'''


def build_system_prompt(tools: list[dict]) -> str:
    """根据工具列表动态生成完整 system prompt"""
    lines = [SYSTEM_PROMPT_BASE, '', '## 工具', '', '你可以使用以下工具：']
    for t in tools:
        fn = t['function']
        name = fn['name']
        desc = fn['description']
        if name.startswith('create_') or name.startswith('update_') or name.startswith('delete_'):
            continue
        lines.append(f'- {name}: {desc}')
    lines.append('- create_memory / update_memory / delete_memory: 管理记忆库')
    return '\n'.join(lines)

TOOLS = [
    {
        'type': 'function',
        'function': {
            'name': 'load_conversation',
            'description': '载入指定对话的完整消息。仅当摘要不够、需要查看细节时调用。',
            'parameters': {
                'type': 'object',
                'properties': {
                    'conversation_id': {'type': 'string', 'description': '要载入的对话ID'},
                },
                'required': ['conversation_id'],
            },
        },
    },
    {
        'type': 'function',
        'function': {
            'name': 'load_memory',
            'description': '载入指定记忆的完整内容。仅在 list_memories 的索引摘要不够时调用。',
            'parameters': {
                'type': 'object',
                'properties': {
                    'id': {'type': 'string', 'description': '记忆ID（从 list_memories 获取）'},
                },
                'required': ['id'],
            },
        },
    },
    {
        'type': 'function',
        'function': {
            'name': 'search_web',
            'description': '搜索互联网获取最新信息。',
            'parameters': {
                'type': 'object',
                'properties': {
                    'query': {'type': 'string', 'description': '搜索词'},
                },
                'required': ['query'],
            },
        },
    },
    {
        'type': 'function',
        'function': {
            'name': 'search_arxiv',
            'description': '搜索 arxiv 学术论文。适合查最新研究、技术论文。',
            'parameters': {
                'type': 'object',
                'properties': {
                    'query': {'type': 'string', 'description': '搜索词'},
                },
                'required': ['query'],
            },
        },
    },
    {
        'type': 'function',
        'function': {
            'name': 'search_hackernews',
            'description': '搜索 HackerNews 技术新闻和讨论。适合查技术圈热门话题。',
            'parameters': {
                'type': 'object',
                'properties': {
                    'query': {'type': 'string', 'description': '搜索词'},
                },
                'required': ['query'],
            },
        },
    },
    {
        'type': 'function',
        'function': {
            'name': 'search_github',
            'description': '搜索 GitHub 热门仓库。适合发现新开源项目。',
            'parameters': {
                'type': 'object',
                'properties': {
                    'query': {'type': 'string', 'description': '搜索词，如语言名或关键词。不传则返回全站热门'},
                },
                'required': [],
            },
        },
    },
    {
        'type': 'function',
        'function': {
            'name': 'fetch_url',
            'description': '抓取指定网页的完整正文内容。搜索结果只有摘要不够时，用这个深入阅读原文。',
            'parameters': {
                'type': 'object',
                'properties': {
                    'url': {'type': 'string', 'description': '要抓取的网页 URL'},
                },
                'required': ['url'],
            },
        },
    },
    {
        'type': 'function',
        'function': {
            'name': 'create_memory',
            'description': '创建一条新的长期记忆。name 用 kebab-case 做唯一标识（如 dislike-structured-summary）。description 是一行索引摘要。完整的记忆内容放在 content。type 可选 fact/feedback/observation/self_correction。',
            'parameters': {
                'type': 'object',
                'properties': {
                    'name': {'type': 'string', 'description': 'kebab-case 唯一标识，如 into-philosophy'},
                    'description': {'type': 'string', 'description': '一行索引摘要，用于召回匹配'},
                    'content': {'type': 'string', 'description': '记忆全文'},
                    'type': {'type': 'string', 'description': 'fact/feedback/observation/self_correction'},
                },
                'required': ['name', 'description', 'content'],
            },
        },
    },
    {
        'type': 'function',
        'function': {
            'name': 'update_memory',
            'description': '修改一条已有的长期记忆。可以只改部分字段。',
            'parameters': {
                'type': 'object',
                'properties': {
                    'id': {'type': 'string', 'description': '记忆ID（从 list_memories 获取）'},
                    'name': {'type': 'string', 'description': '新的唯一标识（可选）'},
                    'description': {'type': 'string', 'description': '新的一行摘要（可选）'},
                    'content': {'type': 'string', 'description': '新的完整内容（可选）'},
                    'type': {'type': 'string', 'description': '新类型（可选）'},
                },
                'required': ['id'],
            },
        },
    },
    {
        'type': 'function',
        'function': {
            'name': 'delete_memory',
            'description': '删除一条长期记忆。',
            'parameters': {
                'type': 'object',
                'properties': {
                    'id': {'type': 'string', 'description': '记忆ID（从 list_memories 获取）'},
                },
                'required': ['id'],
            },
        },
    },
    {
        'type': 'function',
        'function': {
            'name': 'update_conversation',
            'description': '更新当前对话的标题和摘要。',
            'parameters': {
                'type': 'object',
                'properties': {
                    'title': {'type': 'string', 'description': '新标题'},
                    'summary': {'type': 'string', 'description': '新摘要'},
                },
                'required': [],
            },
        },
    },
]

# ===== 场景工具子集 =====

CHAT_TOOLS = TOOLS  # 聊天：全量工具

ARCHIVE_TOOLS = [
    t for t in TOOLS
    if t['function']['name'] in (
        'load_memory',
        'create_memory', 'update_memory', 'delete_memory',
    )
] + [
    {
        'type': 'function',
        'function': {
            'name': 'finalize_archive',
            'description': (
                '提交归档分段方案。每条消息必须归属于某一段，不能遗漏、不能重叠。'
                '调用后不要写任何文字回复。'
            ),
            'parameters': {
                'type': 'object',
                'properties': {
                    'segments': {
                        'type': 'array',
                        'items': {
                            'type': 'object',
                            'properties': {
                                'start': {'type': 'integer', 'description': '起始消息编号'},
                                'end': {'type': 'integer', 'description': '结束消息编号'},
                                'title': {'type': 'string', 'description': '段落标题'},
                                'summary': {'type': 'string', 'description': '段落摘要'},
                            },
                            'required': ['start', 'end', 'title', 'summary'],
                        },
                    },
                },
                'required': ['segments'],
            },
        },
    },
]

EXPLORE_TOOLS = CHAT_TOOLS  # 探索 = AI 先说话的聊天

# Serper API（对标 Flutter 端 search_web 工具）
SERPER_API_KEY = os.environ.get('SERPER_API_KEY', 'f5906a5321623f7d082d5a2eb7a20a07291cba69')


# ===== 核心 API 调用 =====

def send_request(messages: list[dict], temperature: float = 0.7,
                 tools: list[dict] | None = None) -> dict:
    """对标 Flutter AiService.sendRequest()

    返回 {'content': str|None, 'reasoning': str|None, 'tool_calls': list|None}
    """
    body = {
        'model': DEEPSEEK_MODEL,
        'messages': messages,
        'temperature': temperature,
    }
    if tools:
        body['tools'] = tools

    resp = requests.post(
        f'{DEEPSEEK_BASE_URL}/chat/completions',
        headers={
            'Authorization': f'Bearer {DEEPSEEK_API_KEY}',
            'Content-Type': 'application/json',
        },
        json=body,
        timeout=120,
    )

    if resp.status_code != 200:
        raise RuntimeError(f'DeepSeek API error ({resp.status_code}): {resp.text[:500]}')

    data = resp.json()
    choice = data['choices'][0]
    msg = choice['message']

    result = {
        'content': msg.get('content'),
        'reasoning': msg.get('reasoning_content'),
        'tool_calls': None,
    }

    if msg.get('tool_calls'):
        result['tool_calls'] = [
            {
                'id': tc['id'],
                'name': tc['function']['name'],
                'arguments': json.loads(tc['function']['arguments']),
            }
            for tc in msg['tool_calls']
        ]

    return result


def build_messages(tools: list[dict], conversation: list[dict],
                   date_note: str | None = None,
                   memory_index: str | None = None,
                   history_index: str | None = None,
                   extra_indexes: dict[str, str] | None = None) -> list[dict]:
    """构建消息列表 — soul 文件 + 动态 system prompt + 索引"""
    from config import SOUL_PATH

    messages = []

    soul_content = ''
    try:
        with open(SOUL_PATH, 'r', encoding='utf-8') as f:
            soul_content = f.read().strip()
    except Exception:
        pass

    sys_content = ''
    if soul_content:
        sys_content += soul_content + '\n\n---\n\n'
    sys_content += build_system_prompt(tools)
    if date_note:
        sys_content += f'\n\n[日期信息]\n{date_note}'
    if history_index:
        sys_content += f'\n\n[历史对话索引]\n{history_index}'
    if memory_index:
        sys_content += f'\n\n[记忆索引]\n{memory_index}'
    if extra_indexes:
        for key, val in extra_indexes.items():
            sys_content += f'\n\n[{key}]\n{val}'

    messages.append({'role': 'system', 'content': sys_content})
    messages.extend(conversation)
    return messages


# ===== 归档 =====

def archive_conversation(messages: list[dict], existing_memories: list[str] | None = None,
                         tag_library: list[str] | None = None,
                         user_instruction: str = '') -> dict:
    """对标 Flutter AiService.archiveConversation()"""
    instr = f'\n用户的归档要求：{user_instruction}' if user_instruction else ''
    existing = ''
    if existing_memories:
        existing = '\n已有的长期记忆（不要输出重复的）：\n' + \
            '\n'.join(f'{i+1}. {m}' for i, m in enumerate(existing_memories))
    taglib = ''
    if tag_library:
        taglib = '\n现有标签：' + '、'.join(tag_library) + '。优先从现有标签中选，没有合适的可以返回新标签名。'

    prompt = f'''你是一个日记归档助手。这是用户主动触发的归档，分析以下对话，返回 JSON。

{instr}
{taglib}
{existing}

按话题切换点切分对话，不同话题分成不同的段。2-5段为宜。

返回格式（严格 JSON，不要其他文字）：
{{
  "segments": [
    {{
      "title": "段落标题（15字以内）",
      "tags": ["标签1", "标签2"],
      "summary": "一段话总结信息量内容，去掉寒暄和废话，保留事实、决定、进展、情绪要点",
      "memories": ["可跨会话检索的原子事实1"],
      "startIndex": 0,
      "endIndex": 4
    }}
  ]
}}

规则：
- tags 每段1-3个标签。优先选现有标签，没有合适的就创建新标签（返回新名字）
- 内容确实没有合适标签时 tags 可以是空数组 []
- 每条消息都要归属于某一段，不要遗漏，不要重叠
- 如果整段对话只有一个话题，就返回一段
- summary 只保留有信息价值的内容，不说"用户和助手聊了xx"这种废话
- memories 每一条是独立原子事实'''

    full = [{'role': 'system', 'content': prompt}] + messages
    result = send_request(full, temperature=0.2)
    raw = (result.get('content') or '').strip()
    if raw.startswith('```'):
        raw = raw.split('```')[1]
        if raw.startswith('json'):
            raw = raw[4:]
    return json.loads(raw.strip())


def auto_archive(messages: list[dict], existing_summary: str | None = None,
                 existing_memories: list[str] | None = None) -> dict:
    """对标 Flutter AiService.autoArchive()"""
    existing_note = f'\n之前的摘要：{existing_summary}' if existing_summary else ''
    memories_part = ''
    if existing_memories:
        memories_part = '\n已有的长期记忆（不要输出重复的，除非有更新）：\n' + \
            '\n'.join(f'{i+1}. {m}' for i, m in enumerate(existing_memories))

    prompt = f'''你是日记归档助手。这是一段自动归档，不需要用户干预。

{existing_note}

{memories_part}
重要：这段对话视为一个整体话题，不要拆分。只返回一段。

返回严格 JSON：
{{
  "title": "会话标题（15字以内）",
  "tags": ["标签1"],
  "summary": "一段话总结信息量内容，去掉寒暄和废话",
  "memories": ["原子事实1", "事实2"]
}}'''

    full = [{'role': 'system', 'content': prompt}] + messages
    result = send_request(full, temperature=0.2)
    raw = (result.get('content') or '').strip()
    if raw.startswith('```'):
        raw = raw.split('```')[1]
        if raw.startswith('json'):
            raw = raw[4:]
    return json.loads(raw.strip())



