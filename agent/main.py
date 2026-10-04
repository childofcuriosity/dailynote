"""Start the HTTP API and background account agents."""
import sys
import os
import logging

# Ensure modules in the same directory can be found
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from config import (
    API_HOST, API_PORT, DEEPSEEK_API_KEY, DATA_DIR,
)
from api import app, set_agent
from agent import Agent
from demo_data import seed_demo
from account_context import set_account


def main():
    logging.basicConfig(
        level=logging.INFO,
        format='%(asctime)s [%(name)s] %(levelname)s: %(message)s',
        datefmt='%Y-%m-%d %H:%M:%S',
    )
    logger = logging.getLogger('main')

    # Check required configuration
    if not DEEPSEEK_API_KEY:
        logger.error('DEEPSEEK_API_KEY is not configured.')
        logger.error('Set DEEPSEEK_API_KEY in the environment or .env file.')
        sys.exit(1)

    # Ensure the data directory exists
    os.makedirs(DATA_DIR, exist_ok=True)

    # Start the Agent
    seed_demo()
    demo_agent = Agent(account='demo')
    demo_agent.start()
    set_agent(demo_agent, 'demo')
    set_account('personal')
    agent = Agent()
    agent.start()
    set_agent(agent)

    logger.info('Data directory: {0}'.format(DATA_DIR))
    logger.info('API listening: {0}:{1}'.format(API_HOST, API_PORT))

    try:
        app.run(host=API_HOST, port=API_PORT, debug=False, use_reloader=False)
    except KeyboardInterrupt:
        logger.info('Shutdown signal received')
    finally:
        agent.stop()
        demo_agent.stop()
        logger.info('Goodbye')


if __name__ == '__main__':
    main()
