"""DeepSeek chat-completions client and account-scoped prompt builder."""
from i18n import tr, localized_tools
import json
import logging
import os
import requests
from config import DEEPSEEK_API_KEY, DEEPSEEK_BASE_URL, DEEPSEEK_MODEL

logger = logging.getLogger(__name__)

# ===== Identical to Flutter chat_page.dart =====

SYSTEM_PROMPT_BASE = """The section above contains behavior guidelines written by the account owner. You can read them but cannot modify them.

## Memory types

- fact / observation: background information about the user.
- feedback / self_correction: learned behavior guidelines about what works better and what needs improvement. Follow these when responding.

## Retrieval strategy

The conversation index and memory index are appended to this system prompt.
- Use summaries first; call load_conversation or load_memory only when details are needed.
- Ignore unrelated conversations and memories.
- Use update_memory and delete_memory to correct outdated, incorrect, or duplicate memories."""


def build_system_prompt(tools: list[dict]) -> str:
    """Build a system prompt for the available tools."""
    lines = [tr(SYSTEM_PROMPT_BASE), '', tr('## Tools'), '', tr('You can use the following tools:')]
    lines.append(tr('Use English for all replies, reasoning, discoveries, titles, summaries, and memory content.'))
    for t in localized_tools(tools):
        fn = t['function']
        name = fn['name']
        desc = fn['description']
        if name.startswith('create_') or name.startswith('update_') or name.startswith('delete_'):
            continue
        lines.append(f'- {name}: {desc}')
    lines.append(tr('- create_memory / update_memory / delete_memory: manage long-term memories'))
    return '\n'.join(lines)

TOOLS = [
    {
        'type': 'function',
        'function': {
            'name': 'load_conversation',
            'description': 'Load the full conversation only when its summary is insufficient.',
            'parameters': {
                'type': 'object',
                'properties': {
                    'conversation_id': {'type': 'string', 'description': 'Conversation ID to load'},
                },
                'required': ['conversation_id'],
            },
        },
    },
    {
        'type': 'function',
        'function': {
            'name': 'load_memory',
            'description': 'Load a full memory only when its index description is insufficient.',
            'parameters': {
                'type': 'object',
                'properties': {
                    'id': {'type': 'string', 'description': 'Memory ID from the memory index'},
                },
                'required': ['id'],
            },
        },
    },
    {
        'type': 'function',
        'function': {
            'name': 'search_web',
            'description': 'Search the web for current information.',
            'parameters': {
                'type': 'object',
                'properties': {
                    'query': {'type': 'string', 'description': 'Search query'},
                },
                'required': ['query'],
            },
        },
    },
    {
        'type': 'function',
        'function': {
            'name': 'search_arxiv',
            'description': 'Search arXiv for research and technical papers.',
            'parameters': {
                'type': 'object',
                'properties': {
                    'query': {'type': 'string', 'description': 'Search query'},
                },
                'required': ['query'],
            },
        },
    },
    {
        'type': 'function',
        'function': {
            'name': 'search_hackernews',
            'description': 'Search Hacker News for technology news and discussions. Omit the query for top stories.',
            'parameters': {
                'type': 'object',
                'properties': {
                    'query': {'type': 'string', 'description': 'Search query; omit for top Hacker News stories'},
                },
                'required': [],
            },
        },
    },
    {
        'type': 'function',
        'function': {
            'name': 'search_github',
            'description': 'Search GitHub for popular repositories and new open-source projects.',
            'parameters': {
                'type': 'object',
                'properties': {
                    'query': {'type': 'string', 'description': 'Search query, such as a language or keyword; omit for popular repositories'},
                },
                'required': [],
            },
        },
    },
    {
        'type': 'function',
        'function': {
            'name': 'fetch_url',
            'description': 'Fetch the body of a web page when search snippets are insufficient.',
            'parameters': {
                'type': 'object',
                'properties': {
                    'url': {'type': 'string', 'description': 'URL to fetch'},
                },
                'required': ['url'],
            },
        },
    },
    {
        'type': 'function',
        'function': {
            'name': 'fetch_rendered',
            'description': 'Render a dynamic page in a headless browser and extract its body. Use only when fetch_url returns a page shell, missing text, or loading placeholders. This is slower (about 5-10 seconds).',
            'parameters': {
                'type': 'object',
                'properties': {
                    'url': {'type': 'string', 'description': 'URL to render and fetch'},
                },
                'required': ['url'],
            },
        },
    },
    {
        'type': 'function',
        'function': {
            'name': 'create_memory',
            'description': 'Create a long-term memory. Use a unique kebab-case name, a one-line retrieval description, and full content. Types: fact, feedback, observation, self_correction.',
            'parameters': {
                'type': 'object',
                'properties': {
                    'name': {'type': 'string', 'description': 'Unique kebab-case identifier, e.g. into-philosophy'},
                    'description': {'type': 'string', 'description': 'One-line description for retrieval'},
                    'content': {'type': 'string', 'description': 'Full memory content'},
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
            'description': 'Update an existing memory; partial updates are supported.',
            'parameters': {
                'type': 'object',
                'properties': {
                    'id': {'type': 'string', 'description': 'Memory ID from the memory index'},
                    'name': {'type': 'string', 'description': 'New unique identifier (optional)'},
                    'description': {'type': 'string', 'description': 'New one-line description (optional)'},
                    'content': {'type': 'string', 'description': 'New full content (optional)'},
                    'type': {'type': 'string', 'description': 'New type (optional)'},
                },
                'required': ['id'],
            },
        },
    },
    {
        'type': 'function',
        'function': {
            'name': 'delete_memory',
            'description': 'Delete a long-term memory.',
            'parameters': {
                'type': 'object',
                'properties': {
                    'id': {'type': 'string', 'description': 'Memory ID from the memory index'},
                },
                'required': ['id'],
            },
        },
    },
    {
        'type': 'function',
        'function': {
            'name': 'update_conversation',
            'description': 'Update the current conversation title and summary.',
            'parameters': {
                'type': 'object',
                'properties': {
                    'title': {'type': 'string', 'description': 'New title'},
                    'summary': {'type': 'string', 'description': 'New summary'},
                },
                'required': [],
            },
        },
    },
]

# ===== Scenario tool subset =====

CHAT_TOOLS = TOOLS  # Chat: Full toolset

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
                'Submit the archive segments. Assign every message to exactly one segment, with no gaps or overlaps. Group by broad topics. Do not write a reply after this call.'
            ),
            'parameters': {
                'type': 'object',
                'properties': {
                    'segments': {
                        'type': 'array',
                        'items': {
                            'type': 'object',
                            'properties': {
                                'start': {'type': 'integer', 'description': 'First message index (inclusive)'},
                                'end': {'type': 'integer', 'description': 'Last message index (inclusive)'},
                                'title': {'type': 'string', 'description': 'Segment title'},
                                'summary': {'type': 'string', 'description': 'Segment summary'},
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

EXPLORE_TOOLS = CHAT_TOOLS  # Explore = Chat where AI speaks first

# Serper API (corresponds to the Flutter-side search_web tool)
SERPER_API_KEY = os.environ.get('SERPER_API_KEY', '')


# ===== Core API calls =====

def send_request(messages: list[dict], temperature: float = 0.7,
                 tools: list[dict] | None = None) -> dict:
    """Return content, reasoning, and parsed tool calls from the model."""
    body = {
        'model': DEEPSEEK_MODEL,
        'messages': messages,
        'temperature': temperature,
    }
    if tools:
        body['tools'] = localized_tools(tools)

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
    """Build messages from account guidelines, tools, and retrieval indexes."""
    from account_context import soul_path

    messages = []

    soul_content = ''
    try:
        with open(soul_path(), 'r', encoding='utf-8') as f:
            soul_content = f.read().strip()
    except Exception:
        pass

    sys_content = ''
    if soul_content:
        sys_content += soul_content + '\n\n---\n\n'
    sys_content += build_system_prompt(tools)
    if date_note:
        sys_content += tr('\n\n[Date]\n{0}').format(date_note)
    if history_index:
        sys_content += tr('\n\n[Conversation index]\n{0}').format(history_index)
    if memory_index:
        sys_content += tr('\n\n[Memory index]\n{0}').format(memory_index)
    if extra_indexes:
        for key, val in extra_indexes.items():
            sys_content += f'\n\n[{key}]\n{val}'

    messages.append({'role': 'system', 'content': sys_content})
    messages.extend(conversation)
    return messages




