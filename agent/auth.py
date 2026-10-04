"""Two account sessions; personal credentials never enter the web bundle."""
import os
import secrets
import threading
import time
from pathlib import Path
from flask import request, jsonify, g
from werkzeug.security import check_password_hash
import config
from account_context import set_account
from database import close_db

_sessions = {}
_failures = {}
_lock = threading.Lock()
SESSION_SECONDS = 12 * 3600


def install_auth(app):
    @app.before_request
    def authenticate():
        if request.path == '/session' and request.method == 'POST':
            return None
        token = request.headers.get('Authorization', '').removeprefix('Bearer ')
        with _lock:
            entry = _sessions.get(token)
        if not entry or entry[1] <= time.time():
            return jsonify(error='Choose an account and sign in first'), 401
        g.account = entry[0]
        g.session_token = token
        set_account(g.account)
        if request.path.startswith('/admin/') and g.account != 'personal':
            return jsonify(error='The demo account cannot access admin endpoints'), 403

    @app.after_request
    def private_response(response):
        response.headers['Cache-Control'] = 'no-store'
        return response

    @app.teardown_request
    def cleanup(_error):
        close_db()
        set_account('personal')

    @app.post('/session')
    def login():
        body = request.get_json(silent=True) or {}
        account = body.get('account')
        if account not in ('demo', 'personal'):
            return jsonify(error='Choose a valid account'), 400
        if account == 'personal':
            ip = request.remote_addr
            with _lock:
                attempts = [t for t in _failures.get(ip, []) if t > time.time() - 60]
            if len(attempts) >= 5:
                return jsonify(error='Too many attempts. Try again in one minute.'), 429
            password_hash = os.environ.get('PERSONAL_PASSWORD_HASH', '')
            path = Path(config.DATA_DIR) / 'personal_password.hash'
            if not password_hash and path.exists():
                password_hash = path.read_text(encoding='utf-8').strip()
            if not password_hash:
                return jsonify(error='The personal account password has not been configured'), 503
            password = body.get('password', '')
            if not isinstance(password, str) or not check_password_hash(password_hash, password):
                with _lock:
                    _failures[ip] = attempts + [time.time()]
                return jsonify(error='Incorrect password'), 401
            with _lock:
                _failures.pop(ip, None)
        token = secrets.token_urlsafe(32)
        with _lock:
            for old in [k for k, v in _sessions.items() if v[1] <= time.time()]:
                _sessions.pop(old, None)
            _sessions[token] = (account, time.time() + SESSION_SECONDS)
        return jsonify(account=account, token=token)

    @app.delete('/session')
    def logout():
        with _lock:
            _sessions.pop(g.session_token, None)
        return jsonify(ok=True)
