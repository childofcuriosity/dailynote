import urllib.request, json, time

BASE = 'http://localhost:8081'
TOKEN = None

def api(method, path, data=None):
    url = f'{BASE}{path}'
    req = urllib.request.Request(url, method=method)
    req.add_header('Content-Type', 'application/json')
    if TOKEN:
        req.add_header('Authorization', 'Bearer ' + TOKEN)
    if data:
        req.data = json.dumps(data).encode()
    try:
        with urllib.request.urlopen(req, timeout=180) as resp:
            return json.loads(resp.read())
    except Exception as e:
        return {'error': str(e)}

# 1. Send 3 messages
TOKEN = api('POST', '/session', {'account': 'demo'})['token']
r = api('POST', '/messages?wait=true', {'content': 'I have been learning Rust. Its ownership system is interesting.'})
cid = r['conversation_id']
print(f'conv: {cid}')

api('POST', '/messages?wait=true', {'content': 'The lake was crowded at the weekend; a weekday walk would be nicer.', 'conversation_id': cid})
api('POST', '/messages?wait=true', {'content': 'I also want to set aside twenty minutes a day to learn Python.', 'conversation_id': cid})

# 2. View messages
msgs = api('GET', f'/conversations/{cid}/messages')
print('--- messages ---')
for m in msgs:
    if m['role'] in ('user', 'assistant'):
        print(m['role'], ':', m['content'][:60])

# 3. Archive
print('--- archive ---')
time.sleep(2)
r = api('POST', f'/conversations/{cid}/archive')
print(r)

# 4. Wait 30 seconds for AI to finish processing
time.sleep(40)

# 5. Check the original session
print('--- original ---')
conv = api('GET', f'/conversations/{cid}')
print('archived:', conv.get('archived'))

# 6. Check segments
print('--- segments ---')
convs = api('GET', '/conversations')
for c in convs:
    if c.get('source') == 'archive':
        print(c['id'][:8], c.get('archived'), c['title'][:60])
