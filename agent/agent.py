"""Background agent: replies, tool calls, proactive exploration, and archiving."""
from i18n import tr
from account_context import get_account
import json
import logging
import random
import threading
import time
from datetime import datetime

import requests
from account_context import set_account, debug_path

from database import (
    init_db,
    get_unreplied_conversations, get_recent_conversation_context,
    insert_message, list_memory_contents, list_memories,
    create_conversation,
    list_conversations, get_conversation, get_conversation_tags, list_messages,
    insert_memory, update_memory, delete_memory,
    get_dirty_conversations, update_conversation, set_conversation_tags, now_ms,
    load_memory, get_last_message, copy_message, delete_conversation,
    get_schedule_time, set_schedule_time, latest_exploration_time,
)
from ai_client import (
    send_request, build_messages,
    TOOLS, CHAT_TOOLS, ARCHIVE_TOOLS, EXPLORE_TOOLS, SERPER_API_KEY,
)
from explorer import (
    search_arxiv, search_hackernews, search_github_trending, fetch_url,
    fetch_rendered,
)
from config import (
    CHECK_INTERVAL_MIN, CHECK_INTERVAL_MAX,
    EXPLORE_INTERVAL_DAYS,
)

logger = logging.getLogger(__name__)


class Agent:
    def __init__(self, account: str = 'personal'):
        self.account = account
        self._context = threading.local()
        self._running = False
        self._thread: threading.Thread | None = None
        self._new_message_event = threading.Event()
        self._explore_event = threading.Event()
        self._last_explore_time = 0
        self._today_message_count = 0
        self._today_date = ''
        self._lock = threading.Lock()
        self._exploring = False
        self._reply_events: dict[str, threading.Event] = {}  # conv_id → Event, used for API synchronous waiting
        self._voice_convs: set[str] = set()  # Voice mode sessions, cleaned up after processing
        self._last_archive_time = 0.0

    # ===== Lifecycle =====

    def start(self):
        set_account(self.account)
        init_db()
        self._initialize_schedule()
        self._running = True
        self._thread = threading.Thread(target=self._loop, daemon=True, name='agent-loop')
        self._thread.start()
        logger.info(tr('Agent started'))

    def stop(self):
        self._running = False
        if self._thread:
            self._thread.join(timeout=10)
        logger.info(tr('Agent stopped'))

    def status(self) -> str:
        if not self._running:
            return 'stopped'
        return tr('running (proactive messages today: {0})').format(self._today_message_count)

    def signal_new_message(self, conv_id: str):
        self._new_message_event.set()

    def mark_voice(self, conv_id: str):
        """Mark a conversation for concise spoken responses."""
        self._voice_convs.add(conv_id)

    def wait_for_reply(self, conv_id: str, timeout: float = 120) -> dict | None:
        """Wait for a reply and return the last message."""
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

    # ===== Main loop =====

    def _loop(self):
        set_account(self.account)
        logger.info(tr('Agent loop started'))
        while self._running:
            try:
                self._handle_pending_replies()

                if not self._exploring and (self._explore_event.is_set() or self._should_explore()):
                    self._exploring = True
                    threading.Thread(target=self._do_explore, daemon=True, name='explore').start()
                    self._explore_event.clear()

                # 4. Run automatic archival every few hours
                if self._should_auto_archive():
                    self._auto_archive_dirty()

            except Exception:
                logger.exception('Agent loop error')

            interval = random.randint(CHECK_INTERVAL_MIN, CHECK_INTERVAL_MAX)
            self._new_message_event.wait(timeout=interval)
            self._new_message_event.clear()

    # ===== Reply to user messages (mirroring Flutter _chatLoop + _executeTool) =====

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
                        tr('[Voice mode] Speech recognition may contain errors. Infer intent from context and respond briefly in a conversational style.')}]
                self._process(conv_id, CHAT_TOOLS, extra_messages=extra)
            except Exception:
                logger.exception(tr('Reply to conversation {0} failed').format(conv_id))

    def _process(self, conv_id: str, tools: list[dict],
                 extra_messages: list[dict] | None = None,
                 use_history: bool = True):
        """Shared processing loop for chat, exploration, and archiving."""
        set_account(self.account)
        self._current_conv_id = conv_id
        history = get_recent_conversation_context(conv_id) if use_history else []

        # Exploration/archival inject instructions via extra_messages; history can be empty
        if not extra_messages:
            if not history:
                return
            last = history[-1]
            if last['role'] not in ('user', 'system'):
                return

        # Build conversation history (excluding tool messages—they have no tool_call_id and the API will error)
        # History does not include reasoning: after a new user message starts a new turn, DS allows clearing historical reasoning
        conversation = [
            {'role': m['role'], 'content': m['content']}
            for m in history if m['role'] in ('user', 'assistant', 'system')
        ]
        if extra_messages:
            conversation.extend(extra_messages)

        # Mirrors Flutter _ai.buildMessages(systemPrompt, dateNote, conversation)
        today = datetime.now()
        date_note = tr('Current date: {0}-{1}-{2} {3:02d}:{4:02d}').format(today.year, today.month, today.day, today.hour, today.minute)

        # Build memory index (name + description + type)
        mems = list_memories()
        memory_index = '\n'.join(
            f'[{m["id"]}] [{m.get("type", "fact")}] {m.get("name", m["id"][:8])}: {m.get("description", "")}'
            for m in mems
        ) if mems else tr('No memories yet')

        # Build conversation history index (title + summary + date + tags)
        # Only list archived conversations: unarchived ones duplicate archived content, and exploration conversations are not user-initiated dialogues
        convs = [c for c in list_conversations() if c.get('source') == 'archive']
        history_parts = []
        for c in convs:
            ts = c.get('created_at', 0)
            d = datetime.fromtimestamp(ts / 1000)
            date_str = f'{d.year}-{d.month:02d}-{d.day:02d}'
            tags = get_conversation_tags(c['id'])
            tag_str = f' [{", ".join(tags)}]' if tags else ''
            history_parts.append(
                f'[{c["id"]}] {date_str} | {c["title"]}{tag_str}\n  {c.get("summary") or tr("No summary")}'
            )
        history_index = '\n\n'.join(history_parts) if history_parts else tr('No conversation history yet')

        messages = build_messages(tools, conversation,
                                  date_note=date_note,
                                  memory_index=memory_index,
                                  history_index=history_index)

        # Mirrors Flutter _chatLoop() — up to 5 rounds of function calling
        reasoning = None
        reply = ''
        archive_done = False

        # Collect the tool call chain and store it as one record in the DB after the loop ends
        _thought_chain: list[str] = []

        for loop_count in range(8):
            result = send_request(messages, temperature=0.7, tools=tools)

            if not result['tool_calls']:
                reply = result['content'] or ''
                reasoning = result['reasoning']
                logger.info(tr('AI replied [{0}], tool-call rounds: {1}, reasoning={2} len={3}').format(conv_id, loop_count, bool(reasoning), len(reasoning or '')))
                break

            logger.info(tr('AI tool_calls [{0}] round {1}: {2}').format(conv_id, loop_count + 1, [tc['name'] for tc in result['tool_calls']]))

            reasoning_text = result.get('reasoning')

            # Build tool_calls message (preserve reasoning_content to inject into the next round)
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
                _thought_chain.append(tr('[Reasoning] {0}').format(reasoning_text))

            messages.append(tc_msg)

            # Execute tools and inject results
            for tc in result['tool_calls']:
                tool_result = self._execute_tool(tc['name'], tc['arguments'])
                messages.append({
                    'role': 'tool',
                    'tool_call_id': tc['id'],
                    'content': tool_result if tool_result != '__ARCHIVE_DONE__' else tr('Archive complete.'),
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
            # Rounds exhausted, do not add tools; let the AI reply directly based on existing information
            final = send_request(messages, temperature=0.7, tools=None)
            reply = final['content'] or ''
            reasoning = final['reasoning']

        all_reasoning = list(_thought_chain)
        if reasoning:
            all_reasoning.append(tr('[Reasoning] {0}').format(reasoning))

        if tools is not ARCHIVE_TOOLS:
            if reply or all_reasoning:
                insert_message(conv_id, 'assistant', reply,
                               reasoning='\n\n'.join(all_reasoning) if all_reasoning else None)
        logger.info(tr('Replied to conversation [{0}]').format(conv_id))

        # Debug: Save full prompt (including all function calling rounds + final reply + reasoning)
        debug_msgs = list(messages)
        debug_msgs.append({
            'role': 'assistant',
            'content': reply,
            'reasoning_content': reasoning or '',
        })
        _save_debug_prompt(debug_msgs)

        # Notify API callers waiting synchronously
        event = self._reply_events.pop(conv_id, None)
        if event:
            event.set()

    def _execute_tool(self, name: str, args: dict) -> str:
        """Execute a model tool call within the current account."""
        if name == 'load_conversation':
            conv_id = args['conversation_id']
            msgs = list_messages(conv_id)
            conv = get_conversation(conv_id)
            tags = get_conversation_tags(conv_id)
            header = ''
            if conv:
                tag_str = f' [{", ".join(tags)}]' if tags else ''
                header = tr('Conversation: {0}{1}\n').format(conv['title'], tag_str)
            role_label = {'user': tr('User'), 'assistant': 'AI'}
            return header + '\n'.join(
                f'[{role_label.get(m["role"], m["role"])}]: {m["content"]}'
                for m in msgs
            )

        elif name == 'load_memory':
            m = load_memory(args['id'])
            if not m:
                return tr('Memory not found: {0}').format(args['id'])
            return tr('Memory [{0}] {1}\nDescription: {2}\nContent: {3}').format(m.get('type', 'fact'), m.get('name', ''), m.get('description', ''), m['content'])

        elif name == 'search_web':
            return self._search_web(args['query'])

        elif name == 'search_arxiv':
            results = search_arxiv(args['query'])
            if not results:
                return tr('No relevant papers found.')
            return '\n\n'.join(
                f'{r["title"]}\n  {r["summary"]}\n  {r["url"]}'
                for r in results
            )

        elif name == 'search_hackernews':
            results = search_hackernews(args.get('query', ''))
            if not results:
                return tr('No relevant news found.')
            return '\n\n'.join(
                f'{r["title"]}\n  {r["summary"]}\n  {r["url"]}'
                for r in results
            )

        elif name == 'search_github':
            query = args.get('query', '')
            results = search_github_trending(query) if query else search_github_trending()
            if not results:
                return tr('No relevant repositories found.')
            return '\n\n'.join(
                f'{r["title"]}\n  {r["summary"]}\n  {r["url"]}'
                for r in results
            )

        elif name == 'fetch_url':
            return fetch_url(args['url'])

        elif name == 'fetch_rendered':
            return fetch_rendered(args['url'])

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

        return tr('Unknown tool: {0}').format(name)

    @property
    def _current_conv_id(self):
        return self._context.conv_id

    @_current_conv_id.setter
    def _current_conv_id(self, value):
        self._context.conv_id = value

    @staticmethod
    def _search_web(query: str) -> str:
        """Search with Serper, falling back to ddgs."""
        # Serper
        try:
            resp = requests.post(
                'https://google.serper.dev/search',
                headers={
                    'X-API-KEY': SERPER_API_KEY,
                    'Content-Type': 'application/json',
                },
                json={'q': query, 'gl': 'cn' if (get_account() == 'personal') else 'us',
                      'hl': 'zh-cn' if (get_account() == 'personal') else 'en'},
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

        # ddgs fallback
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

        return tr('No search results found.')

    # ===== Active exploration =====

    def _initialize_schedule(self):
        # Each account persists its own schedule in its existing SQLite database.
        set_account(self.account)
        saved = get_schedule_time('explore')
        if saved is None:
            saved = latest_exploration_time()
            if saved is None:
                saved = time.time()
            set_schedule_time('explore', saved)
        self._last_explore_time = saved
        self._last_archive_time = get_schedule_time('archive') or 0.0

    def _should_explore(self) -> bool:
        # Re-read so manual exploration in another process also resets the timer.
        saved = get_schedule_time('explore')
        if saved is not None:
            self._last_explore_time = saved
        return time.time() - self._last_explore_time >= EXPLORE_INTERVAL_DAYS * 86400

    def _do_explore(self):
        """Start an AI-initiated conversation with exploration instructions."""
        set_account(self.account)
        logger.info(tr('Starting exploration...'))
        self._last_explore_time = time.time()
        try:
            set_schedule_time('explore', self._last_explore_time)
            self._do_explore_inner()
        except Exception:
            logger.exception(tr('Exploration failed'))
        finally:
            # Reset regardless of success or failure, otherwise the main loop thinks exploration is still ongoing and exploration halts permanently
            self._exploring = False

    def _do_explore_inner(self):
        # Records of the last 100 explorations (use archive summary if available; otherwise take the original shared text)
        # List enough history to avoid A-B-A-B type repetition
        recent = list_conversations(source='explorer')[:100]
        recent_hint = ''
        for c in recent:
            summary = c.get('summary')
            if summary:
                recent_hint += f'- {summary}\n'
            else:
                for m in reversed(list_messages(c['id'])):
                    if m['role'] == 'assistant' and m.get('content'):
                        recent_hint += f'- {m["content"][:200].replace(chr(10), " ")}\n'
                        break

        # Note: cannot use f'..' if .. else '' directly followed by string concatenation,
        # Python will merge the following string into the else branch, causing instructions to be swallowed
        instruction = (
            tr("""Browse the web with search_arxiv, search_hackernews, search_github, and search_web. Find one fresh, interesting discovery to share with the visitor. Stop after sharing that one discovery.

Use the conversation index for their interests and recent context. The discoveries below were shared previously; do not repeat them.

""")
        )
        if recent_hint:
            instruction += tr('Previously shared discoveries (do not repeat):\n{0}\n').format(recent_hint)
        instruction += tr('If nothing is worth sharing, reply exactly "Nothing to share today".')

        today = datetime.now().strftime('%m-%d')
        conv = create_conversation(title=tr('🤖 AI discovery {0}').format(today), source='explore_raw')
        # For extra, use user role: with no conversation context DeepSeek will ignore the second system message,
        # Only by passing instructions via user will the model definitely respond
        self._process(conv['id'], EXPLORE_TOOLS,
                      extra_messages=[{'role': 'user', 'content': instruction}])

        # Archive immediately after exploration completes, so next time an informative summary can be seen
        last = get_last_message(conv['id'])
        if last and last['role'] == 'assistant' and not last.get('content', '').strip().startswith(tr('Nothing to share today')):
            self._archive_conversation(conv['id'])

        last = get_last_message(conv['id'])
        if last and last['role'] == 'assistant' and last.get('content', '').strip().startswith(tr('Nothing to share today')):
            update_conversation(conv['id'], hidden=True)
            logger.info(tr('Exploration: nothing worth sharing'))

        self._increment_today_count()

    # ===== Automatic archiving =====

    def _should_auto_archive(self) -> bool:
        """Check for conversations to archive every four hours."""
        return time.time() - self._last_archive_time > 4 * 3600

    def _archive_conversation(self, conv_id: str):
        """Run the shared manual and automatic archive workflow."""
        msgs = list_messages(conv_id)
        if not msgs:
            return

        # Write the message numbers into the instruction so the AI doesn't have to count
        numbered = '\n'.join(
            f'[{i}] [{m["role"]}]: {m["content"]}'
            for i, m in enumerate(msgs)
        )

        instruction = (
            tr("""Archive this conversation in order:
1. Inspect relevant existing memories with load_memory to avoid duplicates.
2. Use create_memory for new facts, preferences, and observations; use update_memory for revisions.
3. Call finalize_archive once to submit the segments.

Group by broad topics. Assign every message exactly once, with indices from 0 to {0}, with no gaps or overlaps.

--- Full conversation with message indices ---
{1}""").format(len(msgs) - 1, numbered)
        )
        # The archiving instruction uses the system role + no history messages: the full conversation is already embedded in the instruction text,
        # There is no assistant message in the history, so DS's reasoning return verification cannot be triggered
        self._process(conv_id, ARCHIVE_TOOLS,
                      extra_messages=[{'role': 'system', 'content': instruction}],
                      use_history=False)
        # Fallback: even if finalize_archive fails, mark as archived to avoid repeated scanning
        update_conversation(conv_id, archived=True, last_archived_at=now_ms())
        logger.info(tr('Archived conversation [{0}]').format(conv_id))

    def _do_finalize_archive(self, segments: list[dict]) -> str:
        """Validate coverage, copy segments, and mark the source as archived."""
        conv_id = self._current_conv_id
        msgs = list_messages(conv_id)
        msg_count = len(msgs)

        # Verification: cover all numbers, no omissions, no duplicates, no out-of-bounds
        covered = set()
        for seg in segments:
            for i in range(seg['start'], seg['end'] + 1):
                if i in covered:
                    return tr('Error: message [{0}] belongs to multiple segments').format(i)
                if i < 0 or i >= msg_count:
                    return tr('Error: message [{0}] is out of bounds (total: {1}; indices: 0-{2})').format(i, msg_count, msg_count - 1)
                covered.add(i)
        expected = set(range(msg_count))
        if covered != expected:
            missing = sorted(expected - covered)
            extra = sorted(covered - expected)
            parts = []
            if missing:
                parts.append(tr('Missing: {0}').format(missing))
            if extra:
                parts.append(tr('Out of bounds: {0}').format(extra))
            return tr('Error: incomplete message coverage. ').format() + '，'.join(parts)

        # Execute: create segments and copy messages
        # The archive products from the exploration source session (explore_raw) continue to be called explorer; user archives are called archive
        src = get_conversation(conv_id)
        new_source = 'explorer' if src and src.get('source') == 'explore_raw' else 'archive'
        for seg in segments:
            new_conv = create_conversation(title=seg['title'], source=new_source)
            new_id = new_conv['id']
            for i in range(seg['start'], seg['end'] + 1):
                copy_message(msgs[i]['id'], new_id)
            update_conversation(new_id, title=seg['title'],
                              summary=seg.get('summary', ''),
                              last_archived_at=now_ms())

        # Mark the original session as archived
        update_conversation(conv_id, archived=True, last_archived_at=now_ms())
        return '__ARCHIVE_DONE__'

    def _auto_archive_dirty(self):
        """Archive eligible conversations on the scheduled scan."""
        logger.info(tr('Auto-archive: scanning eligible conversations...'))
        self._last_archive_time = time.time()
        set_schedule_time('archive', self._last_archive_time)

        dirty = get_dirty_conversations()
        if not dirty:
            logger.info(tr('Auto-archive: no eligible conversations'))
            return

        logger.info(tr('Auto-archive: found {0} eligible conversations').format(len(dirty)))
        for conv in dirty:
            try:
                self._archive_conversation(conv['id'])
            except Exception:
                logger.exception(tr('Auto-archive failed [{0}]').format(conv['id']))

    def _reset_daily_counter(self):
        today = datetime.now().strftime('%Y%m%d')
        if self._today_date != today:
            self._today_date = today
            self._today_message_count = 0

    def _increment_today_count(self):
        self._reset_daily_counter()
        self._today_message_count += 1


# ===== Debug: Save the last complete input received by AI =====

import os as _os
import json as _json

_DEBUG_FILE = _os.path.join(_os.path.dirname(_os.path.abspath(__file__)), 'data', 'last_prompt.json')


def _save_debug_prompt(messages: list[dict]):
    """Save the most recent model conversation for debugging."""
    try:
        path = debug_path()
        _os.makedirs(_os.path.dirname(path), exist_ok=True)
        with open(path, 'w', encoding='utf-8') as f:
            _json.dump(messages, f, ensure_ascii=False, indent=2)
    except Exception:
        pass


def get_last_prompt() -> dict | None:
    """Read the most recent debug prompt."""
    try:
        path = debug_path()
        if _os.path.exists(path):
            with open(path, 'r', encoding='utf-8') as f:
                return _json.load(f)
    except Exception:
        pass
    return None
