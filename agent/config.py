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
API_PORT = int(os.environ.get('API_PORT', '8080'))

# ===== Agent 行为 =====
CHECK_INTERVAL_MIN = int(os.environ.get('CHECK_INTERVAL_MIN', '30'))    # 最短检查间隔（秒）
CHECK_INTERVAL_MAX = int(os.environ.get('CHECK_INTERVAL_MAX', '120'))   # 最长检查间隔（秒）
EXPLORE_COOLDOWN_MIN = int(os.environ.get('EXPLORE_COOLDOWN_MIN', '4'))  # 探索冷却时间（小时）
EXPLORE_COOLDOWN_MAX = int(os.environ.get('EXPLORE_COOLDOWN_MAX', '12')) # 探索最大间隔（小时）
EXPLORE_PROBABILITY = float(os.environ.get('EXPLORE_PROBABILITY', '0.3'))  # 每次检查时探索的概率（冷却过后）

# ===== Soul 文件 =====
SOUL_PATH = os.environ.get(
    'SOUL_PATH',
    os.path.join(os.path.dirname(os.path.abspath(__file__)), 'agent_soul.md'),
)

# ===== FCM（先占位）=====
FCM_CREDENTIALS_PATH = os.environ.get('FCM_CREDENTIALS_PATH', '')
