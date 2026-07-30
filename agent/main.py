"""入口 — 启动 HTTP API + Agent 后台循环"""
import sys
import os
import logging

# 确保能找到同目录的模块
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from config import (
    API_HOST, API_PORT, DEEPSEEK_API_KEY, DATA_DIR,
)
from api import app, set_agent
from agent import Agent


def main():
    logging.basicConfig(
        level=logging.INFO,
        format='%(asctime)s [%(name)s] %(levelname)s: %(message)s',
        datefmt='%Y-%m-%d %H:%M:%S',
    )
    logger = logging.getLogger('main')

    # 检查必需配置
    if not DEEPSEEK_API_KEY:
        logger.error('❌ DEEPSEEK_API_KEY 未设置！')
        logger.error('  请在环境变量或 .env 文件中设置: export DEEPSEEK_API_KEY=sk-xxx')
        sys.exit(1)

    # 确保数据目录存在
    os.makedirs(DATA_DIR, exist_ok=True)

    # 启动 Agent
    agent = Agent()
    agent.start()
    set_agent(agent)

    logger.info(f'📂 数据目录: {DATA_DIR}')
    logger.info(f'🌐 API 监听: {API_HOST}:{API_PORT}')

    try:
        app.run(host=API_HOST, port=API_PORT, debug=False, use_reloader=False)
    except KeyboardInterrupt:
        logger.info('收到退出信号')
    finally:
        agent.stop()
        logger.info('再见 👋')


if __name__ == '__main__':
    main()
