"""Account scope is bound independently in every request and worker thread."""
import os
import threading
import config

_local = threading.local()


def set_account(account: str):
    if account not in ('personal', 'demo'):
        raise ValueError('Unknown account')
    _local.account = account


def get_account() -> str:
    return getattr(_local, 'account', 'personal')


def database_path() -> str:
    if get_account() == 'demo':
        return os.path.join(config.DATA_DIR, 'demo', 'dailynote.db')
    return config.DATABASE_PATH


def soul_path() -> str:
    if get_account() == 'demo':
        return os.path.join(config.DATA_DIR, 'demo', 'agent_soul.md')
    return config.SOUL_PATH


def debug_path() -> str:
    directory = config.DATA_DIR
    if get_account() == 'demo':
        directory = os.path.join(directory, 'demo')
    return os.path.join(directory, 'last_prompt.json')
