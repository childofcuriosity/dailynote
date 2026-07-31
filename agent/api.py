"""HTTP API — 给 Flutter App 调用的 REST 接口"""
import json
import threading
from datetime import datetime
from flask import Flask, request, jsonify
from database import (
    list_conversations, get_conversation, create_conversation,
    update_conversation, delete_conversation, touch_conversation,
    list_messages, insert_message,
    list_memories, insert_memory, update_memory, delete_memory,
    list_tags, create_tag, delete_tag, set_conversation_tags, get_conversation_tags,
    now_ms, get_conversation_count,
)

app = Flask(__name__)
app.json.ensure_ascii = False  # 中文不转义

_agent = None


def set_agent(agent_ref):
    global _agent
    _agent = agent_ref


def _normalize_conv(c: dict) -> dict:
    """SQLite 存 0/1，Flutter 期望 true/false"""
    c['pinned'] = bool(c.get('pinned', 0))
    c['hidden'] = bool(c.get('hidden', 0))
    c['archived'] = bool(c.get('archived', 0))
    return c


# ===== Conversations =====

@app.get('/conversations')
def api_list_conversations():
    convs = list_conversations()
    for c in convs:
        c['tags'] = get_conversation_tags(c['id'])
    return jsonify([_normalize_conv(c) for c in convs])


@app.get('/conversations/<conv_id>')
def api_get_conversation(conv_id):
    conv = get_conversation(conv_id)
    if not conv:
        return jsonify({'error': 'not found'}), 404
    conv['tags'] = get_conversation_tags(conv_id)
    return jsonify(_normalize_conv(conv))


@app.post('/conversations')
def api_create_conversation():
    body = request.get_json(silent=True) or {}
    title = body.get('title', '新对话')
    conv = create_conversation(title=title, source=body.get('source', 'user'))
    return jsonify(conv), 201


@app.put('/conversations/<conv_id>')
def api_update_conversation(conv_id):
    body = request.get_json(silent=True) or {}
    update_conversation(conv_id, **body)
    if 'tags' in body:
        set_conversation_tags(conv_id, body['tags'])
    return jsonify({'ok': True})


@app.delete('/conversations/<conv_id>')
def api_delete_conversation(conv_id):
    delete_conversation(conv_id)
    return jsonify({'ok': True})


@app.get('/conversations/<conv_id>/messages')
def api_list_messages(conv_id):
    msgs = list_messages(conv_id)
    return jsonify(msgs)


# ===== Messages =====

@app.post('/messages')
def api_send_message():
    """用户发送消息

    ?wait=true  同步等待 AI 回复完成后返回（给 Flutter App 用）
    不带 wait   立即返回，AI 后台异步回复
    """
    body = request.get_json(silent=True) or {}
    conv_id = body.get('conversation_id', '')
    content = body.get('content', '').strip()
    voice_mode = body.get('voice', False)
    wait = request.args.get('wait', '').lower() == 'true'

    if not content:
        return jsonify({'error': 'content is required'}), 400

    if not conv_id:
        conv = create_conversation(title=content[:30])
        conv_id = conv['id']

    conv = get_conversation(conv_id)
    if not conv:
        return jsonify({'error': 'conversation not found'}), 404

    insert_message(conv_id, 'user', content)

    # 语音模式：标记会话，agent 处理时通过 extra_messages 注入风格指令
    if voice_mode and _agent:
        _agent.mark_voice(conv_id)

    if wait and _agent:
        _agent.wait_for_reply(conv_id, timeout=180)
        msgs = list_messages(conv_id)
        return jsonify({'conversation_id': conv_id, 'messages': msgs}), 201
    elif _agent:
        _agent.signal_new_message(conv_id)

    return jsonify({'conversation_id': conv_id, 'status': 'processing'}), 201


# ===== Fork =====

@app.post('/conversations/<conv_id>/fork')
def api_fork_conversation(conv_id):
    """Fork: 拷贝源会话前 count 条消息到新会话"""
    body = request.get_json(silent=True) or {}
    count = body.get('count', 0)
    title = body.get('title', 'Fork')

    new_conv = create_conversation(title=title)
    new_id = new_conv['id']

    if count > 0:
        msgs = list_messages(conv_id)[:count]
        for m in msgs:
            insert_message(new_id, m['role'], m['content'])

    update_conversation(new_id, forked_from=conv_id)
    return jsonify({'id': new_id}), 201


# ===== Memories =====

@app.get('/memories')
def api_list_memories():
    return jsonify(list_memories())


@app.post('/memories')
def api_create_memory():
    body = request.get_json(silent=True) or {}
    content = body.get('content', '').strip()
    if not content:
        return jsonify({'error': 'content is required'}), 400
    mid = insert_memory(
        content,
        source_conv_id=body.get('source_conv_id'),
        name=body.get('name', ''),
        description=body.get('description', ''),
        mem_type=body.get('type', 'fact'),
    )
    return jsonify({'id': mid}), 201


@app.put('/memories/<mid>')
def api_update_memory(mid):
    body = request.get_json(silent=True) or {}
    kwargs = {}
    if 'content' in body:
        kwargs['content'] = body['content']
    if 'name' in body:
        kwargs['name'] = body['name']
    if 'description' in body:
        kwargs['description'] = body['description']
    if 'type' in body:
        kwargs['mem_type'] = body['type']
    update_memory(mid, **kwargs)
    return jsonify({'ok': True})


@app.delete('/memories/<mid>')
def api_delete_memory(mid):
    delete_memory(mid)
    return jsonify({'ok': True})


# ===== Tags =====

@app.get('/tags')
def api_list_tags():
    return jsonify(list_tags())


@app.post('/tags')
def api_create_tag():
    body = request.get_json(silent=True) or {}
    name = body.get('name', '').strip()
    if not name:
        return jsonify({'error': 'name is required'}), 400
    tid = create_tag(name)
    return jsonify({'id': tid, 'name': name}), 201


@app.delete('/tags/<tag_id>')
def api_delete_tag(tag_id):
    delete_tag(tag_id)
    return jsonify({'ok': True})


@app.post('/conversations/<conv_id>/tags')
def api_set_conversation_tags(conv_id):
    body = request.get_json(silent=True) or {}
    tag_names = body.get('tags', [])
    set_conversation_tags(conv_id, tag_names)
    return jsonify({'ok': True})


# ===== Soul =====

@app.get('/soul')
def api_get_soul():
    """读取 agent_soul.md"""
    from config import SOUL_PATH
    try:
        with open(SOUL_PATH, 'r', encoding='utf-8') as f:
            return jsonify({'content': f.read()})
    except Exception:
        return jsonify({'content': ''})


@app.put('/soul')
def api_update_soul():
    """写入 agent_soul.md"""
    from config import SOUL_PATH
    body = request.get_json(silent=True) or {}
    content = body.get('content', '')
    if not content:
        return jsonify({'error': 'content is required'}), 400
    try:
        with open(SOUL_PATH, 'w', encoding='utf-8') as f:
            f.write(content)
        return jsonify({'ok': True})
    except Exception as e:
        return jsonify({'error': str(e)}), 500


# ===== Archive =====

@app.post('/conversations/<conv_id>/archive')
def api_archive_conversation(conv_id):
    """手动归档 — 委托 Agent 用同样的 function calling 流程"""
    if _agent:
        _agent._archive_conversation(conv_id)
        return jsonify({'ok': True})
    return jsonify({'error': 'agent not running'}), 503


# ===== Admin/Status =====

@app.get('/status')
def api_status():
    conv_count = get_conversation_count()
    mem_count = len(list_memories())
    return jsonify({
        'conversations': conv_count,
        'memories': mem_count,
        'agent_status': _agent and _agent.status() or 'unknown',
    })


@app.get('/admin/last-prompt')
def api_last_prompt():
    """调试：查看最后一次发给 AI 的完整 prompt"""
    from agent import get_last_prompt
    prompt = get_last_prompt()
    if not prompt:
        return jsonify({'error': '还没有请求过 AI'}), 404
    return jsonify({'messages': prompt})


@app.post('/admin/auto-archive')
def api_trigger_auto_archive():
    """手动触发自动归档"""
    if _agent:
        _agent._auto_archive_dirty()
        return jsonify({'ok': True, 'message': '归档扫描完成'})
    return jsonify({'ok': False, 'message': 'agent 未运行'}), 503


@app.post('/admin/explore')
def api_trigger_explore():
    if _agent:
        _agent.signal_explore()
        return jsonify({'ok': True, 'message': '探索已触发'})
    return jsonify({'ok': False, 'message': 'agent 未运行'}), 503


@app.post('/admin/test-tools')
def api_test_tools():
    """调试：直接测试 function calling"""
    from ai_client import send_request, build_messages, TOOLS

    body = request.get_json(silent=True) or {}
    query = body.get('query', '查一下我的所有长期记忆')

    today = datetime.now()
    date_note = f'现在是 {today.year}年{today.month}月{today.day}日 {today.hour:02d}:{today.minute:02d}'
    messages = build_messages(TOOLS, [
        {'role': 'user', 'content': query}
    ], date_note=date_note)

    rounds = []
    for _ in range(5):
        result = send_request(messages, temperature=0.7, tools=TOOLS)
        if not result['tool_calls']:
            rounds.append({'type': 'reply', 'content': (result['content'] or '')[:300]})
            break
        rounds.append({
            'type': 'tool_calls',
            'tools': [{'name': tc['name'], 'args': tc['arguments']} for tc in result['tool_calls']],
        })
        messages.append({
            'role': 'assistant',
            'tool_calls': [
                {
                    'id': tc['id'],
                    'type': 'function',
                    'function': {
                        'name': tc['name'],
                        'arguments': json.dumps(tc['arguments'], ensure_ascii=False),
                    }
                }
                for tc in result['tool_calls']
            ],
        })
        for tc in result['tool_calls']:
            tool_result = _agent._execute_tool(tc['name'], tc['arguments']) if _agent else '(agent not running)'
            rounds.append({'type': 'tool_result', 'name': tc['name'], 'result': tool_result[:300]})
            messages.append({
                'role': 'tool',
                'tool_call_id': tc['id'],
                'content': tool_result,
            })

    return jsonify({'rounds': rounds})
