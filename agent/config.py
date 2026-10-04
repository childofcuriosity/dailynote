import os

# ===== DeepSeek API =====
DEEPSEEK_API_KEY = os.environ.get('DEEPSEEK_API_KEY', '')
DEEPSEEK_BASE_URL = os.environ.get('DEEPSEEK_BASE_URL', 'https://api.deepseek.com/v1')
DEEPSEEK_MODEL = os.environ.get('DEEPSEEK_MODEL', 'deepseek-v4-pro')

# ===== Database =====
DATA_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'data')
DATABASE_PATH = os.environ.get('DATABASE_PATH', os.path.join(DATA_DIR, 'dailynote.db'))

# ===== HTTP API =====
API_HOST = os.environ.get('API_HOST', '0.0.0.0')
API_PORT = int(os.environ.get('API_PORT', '8081'))

# ===== Agent behavior =====
CHECK_INTERVAL_MIN = int(os.environ.get('CHECK_INTERVAL_MIN', '30'))    # Minimum check interval (seconds)
CHECK_INTERVAL_MAX = int(os.environ.get('CHECK_INTERVAL_MAX', '120'))   # Maximum check interval (seconds)
EXPLORE_INTERVAL_DAYS = float(os.environ.get('EXPLORE_INTERVAL_DAYS', '10'))

# ===== Soul file =====
SOUL_PATH = os.environ.get(
    'SOUL_PATH',
    os.path.join(os.path.dirname(os.path.abspath(__file__)), 'agent_soul.md'),
)

# ===== FCM (placeholder for now) =====
FCM_CREDENTIALS_PATH = os.environ.get('FCM_CREDENTIALS_PATH', '')
