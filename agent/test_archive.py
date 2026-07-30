import urllib.request, json, time

BASE = 'http://localhost:8080'

def api(method, path, data=None):
    url = f'{BASE}{path}'
    req = urllib.request.Request(url, method=method)
    req.add_header('Content-Type', 'application/json')
    if data:
        req.data = json.dumps(data).encode()
    try:
        with urllib.request.urlopen(req, timeout=180) as resp:
            return json.loads(resp.read())
    except Exception as e:
        return {'error': str(e)}

# 1. 发 3 条消息
r = api('POST', '/messages?wait=true', {'content': '最近在学Rust，所有权机制挺有意思'})
cid = r['conversation_id']
print(f'conv: {cid}')

api('POST', '/messages?wait=true', {'content': '周末西湖人太多了，工作日去更好', 'conversation_id': cid})
api('POST', '/messages?wait=true', {'content': '对了，米诺地尔还在用吗？脱发最近好转没', 'conversation_id': cid})

# 2. 看消息
msgs = api('GET', f'/conversations/{cid}/messages')
print('--- messages ---')
for m in msgs:
    if m['role'] in ('user', 'assistant'):
        print(m['role'], ':', m['content'][:60])

# 3. 归档
print('--- archive ---')
time.sleep(2)
r = api('POST', f'/conversations/{cid}/archive')
print(r)

# 4. 等 30 秒让 AI 处理完
time.sleep(40)

# 5. 检查原会话
print('--- original ---')
conv = api('GET', f'/conversations/{cid}')
print('archived:', conv.get('archived'))

# 6. 查分段
print('--- segments ---')
convs = api('GET', '/conversations')
for c in convs:
    if c.get('source') == 'archive':
        print(c['id'][:8], c.get('archived'), c['title'][:60])
