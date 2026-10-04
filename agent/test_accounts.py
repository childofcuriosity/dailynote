"""Offline regression tests: authentication and personal/demo isolation."""
import os
import json
import re
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from werkzeug.security import generate_password_hash
import config
import database as db
from account_context import set_account, soul_path
from demo_data import seed_demo
from api import app
from agent import Agent
from ai_client import build_messages, send_request, CHAT_TOOLS, ARCHIVE_TOOLS
from i18n import localized_tools


class AccountTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.settings = patch.multiple(config, DATA_DIR=self.tmp.name,
            DATABASE_PATH=str(Path(self.tmp.name) / 'personal.db'),
            SOUL_PATH=str(Path(self.tmp.name) / 'personal-soul.md'))
        self.settings.start()
        self.env = patch.dict(os.environ, {'PERSONAL_PASSWORD_HASH': generate_password_hash('test-password')})
        self.env.start()
        set_account('personal')
        db.init_db()
        self.personal = db.create_conversation('private diary')['id']
        db.insert_message(self.personal, 'user', 'private content')
        self.memory = db.insert_memory('private memory', name='private')
        Path(soul_path()).write_text('private soul', encoding='utf-8')
        seed_demo()
        db.close_db()
        set_account('personal')
        app.config['TESTING'] = True
        self.client = app.test_client()

    def tearDown(self):
        db.close_db()
        self.env.stop()
        self.settings.stop()
        self.tmp.cleanup()

    def login(self, account):
        response = self.client.post('/session', json={'account': account, 'password': 'test-password'})
        self.assertEqual(response.status_code, 200)
        return {'Authorization': 'Bearer ' + response.json['token']}

    def test_authentication_and_logout(self):
        self.assertEqual(self.client.get('/conversations').status_code, 401)
        self.assertEqual(self.client.post('/session', json={'account':'personal','password':'wrong'}).status_code, 401)
        headers = self.login('personal')
        self.assertEqual(self.client.get('/conversations', headers=headers).json[0]['id'], self.personal)
        self.client.delete('/session', headers=headers)
        self.assertEqual(self.client.get('/conversations', headers=headers).status_code, 401)

    def test_demo_cannot_read_or_modify_personal_data(self):
        demo = self.login('demo')
        rows = self.client.get('/conversations', headers=demo).json
        self.assertEqual(len(rows), 3)
        self.assertNotIn(self.personal, [r['id'] for r in rows])
        self.assertEqual(self.client.get(f'/conversations/{self.personal}', headers=demo).status_code, 404)
        self.assertEqual(self.client.get(f'/conversations/{self.personal}/messages', headers=demo).json, [])
        self.client.delete(f'/conversations/{self.personal}', headers=demo)
        self.client.delete(f'/memories/{self.memory}', headers=demo)
        self.client.put('/soul', headers=demo, json={'content':'demo edit'})
        self.assertEqual(self.client.get('/admin/last-prompt', headers=demo).status_code, 403)
        personal = self.login('personal')
        self.assertEqual(self.client.get('/soul', headers=personal).json['content'], 'private soul')
        self.assertEqual(len(self.client.get('/memories', headers=personal).json), 1)
        self.assertEqual(self.client.get(f'/conversations/{self.personal}', headers=personal).status_code, 200)

    def test_demo_worker_keeps_memory_and_prompts_isolated(self):
        set_account('demo')
        conv = db.create_conversation('demo chat')['id']
        db.insert_message(conv, 'user', 'hello')
        set_account('personal')
        outputs = [
            {'content':None, 'reasoning':None, 'tool_calls':[{'id':'t1','name':'create_memory','arguments':{'content':'demo only','name':'demo-new','description':'demo','type':'fact'}}]},
            {'content':'demo reply', 'reasoning':None, 'tool_calls':None},
        ]
        with patch('agent.send_request', side_effect=outputs):
            Agent(account='demo')._process(conv, [])
        self.assertEqual(len(db.list_memories()), 3)
        self.assertTrue((Path(self.tmp.name) / 'demo' / 'last_prompt.json').exists())
        set_account('personal')
        self.assertEqual(len(db.list_memories()), 1)
        self.assertEqual(db.list_messages(self.personal)[0]['content'], 'private content')

    def test_partial_memory_update(self):
        headers = self.login('personal')
        result = self.client.put(f'/memories/{self.memory}', headers=headers, json={'description':'updated'})
        self.assertEqual(result.status_code, 200)
        memory = self.client.get('/memories', headers=headers).json[0]
        self.assertEqual(memory['description'], 'updated')
        self.assertEqual(memory['content'], 'private memory')

    def test_demo_seed_runs_once(self):
        seed_demo()
        self.assertEqual(len(db.list_conversations()), 3)

    def test_prompts_tools_and_default_titles_follow_account(self):
        for account in ('demo', 'personal', 'demo'):
            set_account(account)
            messages = build_messages(CHAT_TOOLS, [], date_note='2026-10-05',
                                      memory_index='example', history_index='example')
            prompt = messages[0]['content']
            tools = json.dumps(localized_tools(ARCHIVE_TOOLS), ensure_ascii=False)
            title = db.create_conversation()['title']
            if account == 'demo':
                self.assertNotRegex(prompt + tools + title, r'[\u4e00-\u9fff]')
                self.assertIn('Use English for all replies', prompt)
                self.assertEqual(title, 'New conversation')
            else:
                self.assertIn('所有回复', prompt)
                self.assertRegex(tools, r'[\u4e00-\u9fff]')
                self.assertEqual(title, '新对话')
        # Canonical schemas stay English after requests for both accounts.
        self.assertNotRegex(json.dumps(CHAT_TOOLS, ensure_ascii=False), r'[\u4e00-\u9fff]')

    def test_archive_prompt_keeps_numbered_messages_in_both_languages(self):
        for account in ('demo', 'personal'):
            set_account(account)
            worker = Agent(account)
            conv = db.create_conversation()['id']
            db.insert_message(conv, 'user', 'First example message')
            db.insert_message(conv, 'assistant', 'Second example message')
            with patch.object(worker, '_process') as process:
                worker._archive_conversation(conv)
            prompt = process.call_args.kwargs['extra_messages'][0]['content']
            self.assertIn('[0] [user]: First example message', prompt)
            self.assertIn('[1] [assistant]: Second example message', prompt)
            if account == 'demo':
                self.assertNotRegex(prompt, r'[\u4e00-\u9fff]')
                self.assertIn('from 0 to 1', prompt)
            else:
                self.assertIn('请归档这段对话', prompt)

    def test_demo_exploration_skip_is_not_archived(self):
        set_account('demo')
        worker = Agent('demo')
        def reply(conv, tools, **kwargs):
            self.assertNotRegex(kwargs['extra_messages'][0]['content'], r'[\u4e00-\u9fff]')
            db.insert_message(conv, 'assistant', 'Nothing to share today')
        with patch.object(worker, '_process', side_effect=reply), \
             patch.object(worker, '_archive_conversation') as archive:
            worker._do_explore_inner()
        archive.assert_not_called()
        self.assertTrue(db.list_conversations(source='explore_raw')[0]['hidden'])

    def test_demo_seed_is_english(self):
        set_account('demo')
        data = db.list_conversations() + db.list_memory_contents()
        for conv in db.list_conversations():
            data.extend(db.list_messages(conv['id']))
        self.assertNotRegex(json.dumps(data, ensure_ascii=False), r'[\u4e00-\u9fff]')

    def test_request_localizes_tools_without_mutating_original(self):
        with patch('ai_client.requests.post') as post:
            post.return_value.status_code = 200
            post.return_value.json.return_value = {'choices':[{'message':{'content':'ok'}}]}
            for account in ('personal', 'demo'):
                set_account(account)
                send_request([{'role':'user','content':'test'}], tools=CHAT_TOOLS)
                actual = json.dumps(post.call_args.kwargs['json']['tools'], ensure_ascii=False)
                self.assertEqual(bool(re.search(r'[\u4e00-\u9fff]', actual)), account == 'personal')

    def test_ten_day_schedule_survives_restart_and_is_account_scoped(self):
        for account in ('personal', 'demo'):
            worker = Agent(account=account)
            with patch('agent.time.time', return_value=1000):
                worker._initialize_schedule()
                self.assertFalse(worker._should_explore())
            with patch('agent.time.time', return_value=1000 + 10 * 86400 - 1):
                self.assertFalse(worker._should_explore())
            restarted = Agent(account=account)
            with patch('agent.time.time', return_value=1000 + 10 * 86400):
                restarted._initialize_schedule()
                self.assertTrue(restarted._should_explore())
        set_account('demo')
        db.set_schedule_time('explore', 2000)
        set_account('personal')
        self.assertEqual(db.get_schedule_time('explore'), 1000)

    def test_manual_exploration_resets_persistent_schedule(self):
        worker = Agent(account='demo')
        with patch('agent.time.time', return_value=123456), patch.object(worker, '_do_explore_inner') as explore:
            worker._do_explore()
            explore.assert_called_once()
        self.assertEqual(db.get_schedule_time('explore'), 123456)
        self.assertFalse(worker._exploring)

    def test_both_accounts_run_periodic_exploration_and_archive(self):
        for account in ('personal', 'demo'):
            worker = Agent(account=account)
            worker._running = True
            with patch.object(worker, '_handle_pending_replies'), \
                 patch.object(worker, '_should_explore', return_value=True), \
                 patch.object(worker, '_should_auto_archive', return_value=True), \
                 patch.object(worker, '_auto_archive_dirty') as archive, \
                 patch('agent.threading.Thread') as thread, \
                 patch.object(worker._new_message_event, 'wait', side_effect=lambda **kw: setattr(worker, '_running', False)):
                worker._loop()
                thread.return_value.start.assert_called_once()
                archive.assert_called_once()


if __name__ == '__main__':
    unittest.main()
