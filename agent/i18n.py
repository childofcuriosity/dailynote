"""Select prompt text by thread-local account, including background jobs."""
import json
from pathlib import Path
from account_context import get_account

_CHINESE = json.loads((Path(__file__).parent / 'locales' / 'zh.json').read_text(encoding='utf-8'))


def tr(english: str) -> str:
    return _CHINESE.get(english, english) if get_account() == 'personal' else english


def localized_tools(tools):
    """Copy schemas so simultaneous account requests cannot mutate each other."""
    if isinstance(tools, list):
        return [localized_tools(item) for item in tools]
    if isinstance(tools, dict):
        return {key: tr(value) if key == 'description' and isinstance(value, str)
                else localized_tools(value) for key, value in tools.items()}
    return tools
