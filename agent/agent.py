"""Agent 核心 — 常驻循环，监听消息 + function calling 回复 + 主动探索"""
import json
import logging
import random
import threading
import time
from datetime import datetime

import requests

from database import (
    init_db,
    get_unreplied_conversations, get_recent_conversation_context,
    insert_message, list_memory_contents, list_memories,
    create_conversation,
    list_conversations, get_conversation, get_conversation_tags, list_messages,
    insert_memory, update_memory, delete_memory,
    get_dirty_conversations, update_conversation, set_conversation_tags, now_ms,
    load_memory, get_last_message, copy_message, delete_conversation,
)
from ai_client import (
    send_request, build_messages,
    TOOLS, CHAT_TOOLS, ARCHIVE_TOOLS, EXPLORE_TOOLS, SERPER_API_KEY,
)
from explorer import (
    search_arxiv, search_hackernews, search_github_trending, fetch_url,
)
from config import (
    CHECK_INTERVAL_MIN, CHECK_INTERVAL_MAX,
    EXPLORE_COOLDOWN_MIN, EXPLORE_COOLDOWN_MAX,
    EXPLORE_PROBABILITY,
)

logger = logging.getLogger(__name__)


class Agent:
    def __init__(self):
        self._running = False
        self._thread: threading.Thread | None = None
        self._new_message_event = threading.Event()
        self._explore_event = threading.Event()
        self._last_explore_time = 0
        self._today_message_count = 0
        self._today_date = ''
        self._lock = threading.Lock()
        self._exploring = False
        self._reply_events: dict[str, threading.Event] = {}  # conv_id → Event，API 同步等待用
        self._voice_convs: set[str] = set()  # 语音模式的会话，处理后清理
        self._last_archive_time = 0.0

    # ===== 生命周期 =====

    def start(self):
        init_db()
        self._running = True
        self._thread = threading.Thread(target=self._loop, daemon=True, name='agent-loop')
        self._thread.start()
        logger.info('Agent 已启动')

    def stop(self):
        self._running = False
        if self._thread:
            self._thread.join(timeout=10)
        logger.info('Agent 已停止')

    def status(self) -> str:
        if not self._running:
            return 'stopped'
        return f'running (今日已发 {self._today_message_count} 条主动消息)'

    def signal_new_message(self, conv_id: str):
        self._new_message_event.set()

    def mark_voice(self, conv_id: str):
        """标记会话为语音模式，处理时注入口语化风格指令"""
        self._voice_convs.add(conv_id)

    def wait_for_reply(self, conv_id: str, timeout: float = 120) -> dict | None:
        """同步等待某会话的 AI 回复完成，返回最后一条消息"""
        event = threading.Event()
        self._reply_events[conv_id] = event
        self._new_message_event.set()
        if event.wait(timeout=timeout):
            from database import get_last_message
            return get_last_message(conv_id)
        self._reply_events.pop(conv_id, None)
        return None

    def signal_explore(self):
        self._explore_event.set()

    # ===== 主循环 =====

    def _loop(self):
        logger.info('Agent 循环开始')
        while self._running:
            try:
                self._handle_pending_replies()

                if not self._exploring and (self._explore_event.is_set() or self._should_explore()):
                    self._exploring = True
                    threading.Thread(target=self._do_explore, daemon=True, name='explore').start()
                    self._explore_event.clear()

                # 4. 每隔几小时跑一次自动归档
                if self._should_auto_archive():
                    self._auto_archive_dirty()

            except Exception:
                logger.exception('Agent loop error')

            interval = random.randint(CHECK_INTERVAL_MIN, CHECK_INTERVAL_MAX)
            self._new_message_event.wait(timeout=interval)
            self._new_message_event.clear()

    # ===== 回复用户消息（对标 Flutter _chatLoop + _executeTool）=====

    def _handle_pending_replies(self):
        conv_ids = get_unreplied_conversations()
        if not conv_ids:
            return
        for conv_id in conv_ids:
            try:
                extra = None
                if conv_id in self._voice_convs:
                    self._voice_convs.discard(conv_id)
                    extra = [{'role': 'system', 'content':
                        '[语音模式] 用户通过语音输入。语音识别可能有误，结合上下文猜测真实意图。请用口语化、简洁的风格回复，'
                        '像朋友闲聊一样。默认简短，不要长篇大论。除非被追问，不要展开。'}]
                self._process(conv_id, CHAT_TOOLS, extra_messages=extra)
            except Exception:
                logger.exception(f'回复会话 {conv_id} 失败')

    def _process(self, conv_id: str, tools: list[dict],
                 extra_messages: list[dict] | None = None):
        """通用处理入口：聊天/探索/归档共用"""
        self._current_conv_id = conv_id
        history = get_recent_conversation_context(conv_id)

        # 探索/归档通过 extra_messages 注入指令，history 可以为空
        if not extra_messages:
            if not history:
                return
            last = history[-1]
            if last['role'] not in ('user', 'system'):
                return

        # 构建对话历史（不包含 tool 消息——它们没有 tool_call_id，API 会报错）
        conversation = [
            {'role': m['role'], 'content': m['content']}
            for m in history if m['role'] in ('user', 'assistant', 'system')
        ]
        if extra_messages:
            conversation.extend(extra_messages)

        # 对标 Flutter _ai.buildMessages(systemPrompt, dateNote, conversation)
        today = datetime.now()
        date_note = f'今天是 {today.year}年{today.month}月{today.day}日'

        # 构建记忆索引（name + description + type）
        mems = list_memories()
        memory_index = '\n'.join(
            f'[{m["id"]}] [{m.get("type", "fact")}] {m.get("name", m["id"][:8])}: {m.get("description", "")}'
            for m in mems
        ) if mems else '暂无记忆'

        # 构建对话历史索引（title + summary + date + tags）
        convs = list_conversations()
        history_parts = []
        for c in convs:
            ts = c.get('created_at', 0)
            d = datetime.fromtimestamp(ts / 1000)
            date_str = f'{d.year}-{d.month:02d}-{d.day:02d}'
            tags = get_conversation_tags(c['id'])
            tag_str = f' [{", ".join(tags)}]' if tags else ''
            history_parts.append(
                f'[{c["id"]}] {date_str} | {c["title"]}{tag_str}\n  {c.get("summary") or "无摘要"}'
            )
        history_index = '\n\n'.join(history_parts) if history_parts else '暂无历史对话'

        messages = build_messages(tools, conversation,
                                  date_note=date_note,
                                  memory_index=memory_index,
                                  history_index=history_index)

        # 对标 Flutter _chatLoop() — 最多 5 轮 function calling
        reasoning = None
        reply = ''
        archive_done = False

        # 收集工具调用链，循环结束后一条存入 DB
        _thought_chain: list[str] = []

        for loop_count in range(8):
            result = send_request(messages, temperature=0.7, tools=tools)

            if not result['tool_calls']:
                reply = result['content'] or ''
                reasoning = result['reasoning']
                logger.info(f'AI 直接回复 [{conv_id}], tool_calls 轮数: {loop_count}, '
                            f'reasoning={bool(reasoning)} len={len(reasoning or "")}')
                break

            logger.info(f'AI tool_calls [{conv_id}] 第{loop_count+1}轮: '
                        f'{[tc["name"] for tc in result["tool_calls"]]}')

            reasoning_text = result.get('reasoning')

            # 构建 tool_calls 消息（保持 reasoning_content 注入下一轮）
            tc_msg = {
                'role': 'assistant',
                'tool_calls': [
                    {
                        'id': tc['id'],
                        'type': 'function',
                        'function': {
                            'name': tc['name'],
                            'arguments': json.dumps(tc['arguments'], ensure_ascii=False),
                        },
                    }
                    for tc in result['tool_calls']
                ],
            }
            if reasoning_text:
                tc_msg['reasoning_content'] = reasoning_text
                _thought_chain.append(f'[思考] {reasoning_text}')

            messages.append(tc_msg)

            # 执行工具并注入结果
            for tc in result['tool_calls']:
                tool_result = self._execute_tool(tc['name'], tc['arguments'])
                messages.append({
                    'role': 'tool',
                    'tool_call_id': tc['id'],
                    'content': tool_result if tool_result != '__ARCHIVE_DONE__' else '归档完成。',
                })
                if tool_result == '__ARCHIVE_DONE__':
                    archive_done = True
                _thought_chain.append(
                    f'[{tc["name"]}] {json.dumps(tc["arguments"], ensure_ascii=False)}\n'
                    f'{tool_result}'
                )

            if archive_done:
                _thought_chain.clear()
                break
        else:
            # 轮数用尽，不加工具让 AI 基于已有信息直接回复
            final = send_request(messages, temperature=0.7, tools=None)
            reply = final['content'] or ''
            reasoning = final['reasoning']

        all_reasoning = list(_thought_chain)
        if reasoning:
            all_reasoning.append(f'[思考] {reasoning[:500]}')

        if tools is not ARCHIVE_TOOLS:
            if reply or all_reasoning:
                insert_message(conv_id, 'assistant', reply,
                               reasoning='\n\n'.join(all_reasoning) if all_reasoning else None)
        logger.info(f'已回复会话 [{conv_id}]')

        # 调试：保存完整 prompt（含所有 function calling 轮次 + 最终回复 + reasoning）
        debug_msgs = list(messages)
        debug_msgs.append({
            'role': 'assistant',
            'content': reply,
            'reasoning_content': reasoning or '',
        })
        _save_debug_prompt(debug_msgs)

        # 通知同步等待的 API 调用者
        event = self._reply_events.pop(conv_id, None)
        if event:
            event.set()

    def _execute_tool(self, name: str, args: dict) -> str:
        """对标 Flutter _executeTool()"""
        if name == 'load_conversation':
            conv_id = args['conversation_id']
            msgs = list_messages(conv_id)
            conv = get_conversation(conv_id)
            tags = get_conversation_tags(conv_id)
            header = ''
            if conv:
                tag_str = f' [{", ".join(tags)}]' if tags else ''
                header = f'对话: {conv["title"]}{tag_str}\n'
            role_label = {'user': '用户', 'assistant': 'AI'}
            return header + '\n'.join(
                f'[{role_label.get(m["role"], m["role"])}]: {m["content"]}'
                for m in msgs
            )

        elif name == 'load_memory':
            m = load_memory(args['id'])
            if not m:
                return f'未找到记忆 ID:{args["id"]}'
            return f'记忆 [{m.get("type", "fact")}] {m.get("name", "")}\n描述: {m.get("description", "")}\n内容: {m["content"]}'

        elif name == 'search_web':
            return self._search_web(args['query'])

        elif name == 'search_arxiv':
            results = search_arxiv(args['query'])
            if not results:
                return '未找到相关论文。'
            return '\n\n'.join(
                f'{r["title"]}\n  {r["summary"]}\n  {r["url"]}'
                for r in results
            )

        elif name == 'search_hackernews':
            results = search_hackernews(args['query'])
            if not results:
                return '未找到相关新闻。'
            return '\n\n'.join(
                f'{r["title"]}\n  {r["summary"]}\n  {r["url"]}'
                for r in results
            )

        elif name == 'search_github':
            query = args.get('query', '')
            results = search_github_trending(query) if query else search_github_trending()
            if not results:
                return '未找到相关仓库。'
            return '\n\n'.join(
                f'{r["title"]}\n  {r["summary"]}\n  {r["url"]}'
                for r in results
            )

        elif name == 'fetch_url':
            return fetch_url(args['url'])

        elif name == 'create_memory':
            mid = insert_memory(
                content=args['content'],
                name=args.get('name', ''),
                description=args.get('description', ''),
                mem_type=args.get('type', 'fact'),
            )
            return f'created {mid}'

        elif name == 'update_memory':
            kwargs = {}
            if 'content' in args:
                kwargs['content'] = args['content']
            if 'name' in args:
                kwargs['name'] = args['name']
            if 'description' in args:
                kwargs['description'] = args['description']
            if 'type' in args:
                kwargs['mem_type'] = args['type']
            update_memory(args['id'], **kwargs)
            return 'ok'

        elif name == 'delete_memory':
            delete_memory(args['id'])
            return 'ok'

        elif name == 'finalize_archive':
            return self._do_finalize_archive(args['segments'])

        elif name == 'update_conversation':
            kw = {}
            if args.get('title'):
                kw['title'] = args['title']
            if args.get('summary'):
                kw['summary'] = args['summary']
            if kw:
                update_conversation(self._current_conv_id, **kw)
            return 'ok'

        return f'未知工具: {name}'

    @staticmethod
    def _search_web(query: str) -> str:
        """网页搜索 — Serper 优先，ddgs 兜底"""
        # Serper
        try:
            resp = requests.post(
                'https://google.serper.dev/search',
                headers={
                    'X-API-KEY': SERPER_API_KEY,
                    'Content-Type': 'application/json',
                },
                json={'q': query, 'gl': 'cn', 'hl': 'zh-cn'},
                timeout=15,
            )
            if resp.status_code == 200:
                data = resp.json()
                organic = data.get('organic', [])
                if organic:
                    return '\n\n'.join(
                        f'{r.get("title", "")}\n  {r.get("snippet", "")}\n  {r.get("link", "")}'
                        for r in organic[:5]
                    )
        except Exception:
            pass

        # ddgs 兜底
        try:
            from explorer import search_web as ddgs_search
            results = ddgs_search(query)
            if results:
                return '\n\n'.join(
                    f'{r["title"]}\n  {r["summary"]}\n  {r["url"]}'
                    for r in results
                )
        except Exception:
            pass

        return '搜索未找到结果。'

    # ===== 主动探索 =====

    def _should_explore(self) -> bool:
        now = time.time()
        cooldown = random.randint(EXPLORE_COOLDOWN_MIN, EXPLORE_COOLDOWN_MAX) * 3600
        if now - self._last_explore_time < cooldown:
            return False
        return random.random() < EXPLORE_PROBABILITY

    def _do_explore(self):
        """探索 = AI 自己先说话的对话。创建会话 + 系统指令 → _process 处理"""
        logger.info('开始探索...')
        self._last_explore_time = time.time()

        # 最近几次探索的摘要（已归档的标题+摘要，信息量最大）
        recent = list_conversations(source='explorer')[:5]
        recent_hint = ''
        for c in recent:
            summary = c.get('summary', '')
            if summary:
                recent_hint += f'- {c["title"]}: {summary}\n'
            else:
                recent_hint += f'- {c["title"]}\n'

        instruction = (
            f'最近探索过（别重复）：\n{recent_hint}\n' if recent_hint else ''
            '去互联网上逛逛。用你的搜索工具（search_arxiv、search_hackernews、search_github、search_web）'
            '找 2-3 个方向看看，有没有什么值得跟 xhy 分享的——要有趣、有新意。\n\n'
            '不要因为 xhy 的偏好或记忆里的反馈就自我审查探索方向。偶然的惊喜、意外的发现、'
            '甚至不同领域的交叉碰撞，比安全地待在他的已知兴趣圈里更有价值。\n\n'
            '搜到 1-2 个好的就收，用自然的方式分享。翻了一圈没什么值得说的，'
            '就回复"算了，今天没什么特别的"。'
        )

        today = datetime.now().strftime('%m-%d')
        conv = create_conversation(title=f'🤖 AI 探索 {today}', source='explorer')
        self._process(conv['id'], EXPLORE_TOOLS,
                      extra_messages=[{'role': 'system', 'content': instruction}])

        # 探索完成后立刻归档，下次就能看到有信息量的摘要
        last = get_last_message(conv['id'])
        if last and last['role'] == 'assistant' and '算了' not in last.get('content', '')[:10]:
            self._archive_conversation(conv['id'])

        last = get_last_message(conv['id'])
        if last and last['role'] == 'assistant' and '算了' in last.get('content', '')[:10]:
            update_conversation(conv['id'], hidden=True)
            logger.info('探索：没什么值得分享的')

        self._increment_today_count()
        self._exploring = False

    # ===== 自动归档 =====

    def _should_auto_archive(self) -> bool:
        """每隔 4 小时跑一次自动归档"""
        return time.time() - self._last_archive_time > 4 * 3600

    def _archive_conversation(self, conv_id: str):
        """手动和自动归档共用：塞系统指令 → _process 处理"""
        msgs = list_messages(conv_id)
        if len(msgs) < 2:
            return

        # 把消息编号写进 instruction，AI 不用数数
        numbered = '\n'.join(
            f'[{i}] [{m["role"]}]: {m["content"]}'
            for i, m in enumerate(msgs)
        )

        instruction = (
            f'请归档这段对话。处理顺序：\n'
            f'1. 用 load_memory 查看已有记忆，避免重复\n'
            f'2. 提取新的事实/偏好/观察用 create_memory 写入，需要更新的用 update_memory\n'
            f'3. 最后调用 finalize_archive 一次性提交分段方案\n\n'
            f'分段要求：按照话题分段不要太碎，每条消息必须属于某一段，编号从 0 到 {len(msgs)-1}，不漏不重。\n\n'
            f'--- 完整对话（带编号）---\n{numbered}'
        )
        self._process(conv_id, ARCHIVE_TOOLS,
                      extra_messages=[{'role': 'system', 'content': instruction}])
        # 兜底：就算 finalize_archive 失败，也标记已归档避免重复扫描
        update_conversation(conv_id, archived=True, last_archived_at=now_ms())
        logger.info(f'归档完成 [{conv_id}]')

    def _do_finalize_archive(self, segments: list[dict]) -> str:
        """执行 finalize_archive：验证编号 → 创建分段会话 + 拷贝消息 → 标记原会话"""
        conv_id = self._current_conv_id
        msgs = list_messages(conv_id)
        msg_count = len(msgs)

        # 验证：覆盖所有编号，不漏不重不越界
        covered = set()
        for seg in segments:
            for i in range(seg['start'], seg['end'] + 1):
                if i in covered:
                    return f'错误：消息 [{i}] 被多个分段覆盖'
                if i < 0 or i >= msg_count:
                    return f'错误：消息 [{i}] 越界（共 {msg_count} 条，编号 0-{msg_count-1}）'
                covered.add(i)
        expected = set(range(msg_count))
        if covered != expected:
            missing = sorted(expected - covered)
            extra = sorted(covered - expected)
            parts = []
            if missing:
                parts.append(f'缺少：{missing}')
            if extra:
                parts.append(f'越界：{extra}')
            return f'错误：消息覆盖不完整。' + '，'.join(parts)

        # 执行：创建分段，拷贝消息
        for seg in segments:
            new_conv = create_conversation(title=seg['title'], source='archive')
            new_id = new_conv['id']
            for i in range(seg['start'], seg['end'] + 1):
                copy_message(msgs[i]['id'], new_id)
            update_conversation(new_id, title=seg['title'],
                              summary=seg.get('summary', ''),
                              last_archived_at=now_ms())

        # 标记原会话已归档
        update_conversation(conv_id, archived=True, last_archived_at=now_ms())
        return '__ARCHIVE_DONE__'

    def _auto_archive_dirty(self):
        """定时扫描 dirty 会话 → 自动归档"""
        logger.info('自动归档：扫描 dirty 会话...')
        self._last_archive_time = time.time()

        dirty = get_dirty_conversations()
        if not dirty:
            logger.info('自动归档：没有需要归档的会话')
            return

        logger.info(f'自动归档：找到 {len(dirty)} 个 dirty 会话')
        for conv in dirty:
            try:
                self._archive_conversation(conv['id'])
            except Exception:
                logger.exception(f'自动归档失败 [{conv["id"]}]')

    def _reset_daily_counter(self):
        today = datetime.now().strftime('%Y%m%d')
        if self._today_date != today:
            self._today_date = today
            self._today_message_count = 0

    def _increment_today_count(self):
        self._reset_daily_counter()
        self._today_message_count += 1


# ===== 调试：保存最后一次 AI 收到的完整输入 =====

import os as _os
import json as _json

_DEBUG_FILE = _os.path.join(_os.path.dirname(_os.path.abspath(__file__)), 'data', 'last_prompt.json')


def _save_debug_prompt(messages: list[dict]):
    """每次调用 AI 前保存完整 messages 到文件"""
    try:
        _os.makedirs(_os.path.dirname(_DEBUG_FILE), exist_ok=True)
        with open(_DEBUG_FILE, 'w', encoding='utf-8') as f:
            _json.dump(messages, f, ensure_ascii=False, indent=2)
    except Exception:
        pass


def get_last_prompt() -> dict | None:
    """读取最后一次的 prompt"""
    try:
        if _os.path.exists(_DEBUG_FILE):
            with open(_DEBUG_FILE, 'r', encoding='utf-8') as f:
                return _json.load(f)
    except Exception:
        pass
    return None
