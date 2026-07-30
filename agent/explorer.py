"""互联网探索模块 — 搜索不同来源，返回发现"""
import logging
import urllib.parse
import requests
from datetime import datetime

logger = logging.getLogger(__name__)

# arxiv API 很友好，不需 key
ARXIV_API = 'http://export.arxiv.org/api/query'

# HackerNews
HN_API = 'https://hacker-news.firebaseio.com/v0'


def search_arxiv(query: str, max_results: int = 5) -> list[dict]:
    """通过 ddgs 搜 arxiv.org 论文"""
    try:
        from ddgs import DDGS
        results = []
        with DDGS() as ddgs:
            for r in ddgs.text(f'site:arxiv.org {query}', max_results=max_results):
                results.append({
                    'title': r.get('title', ''),
                    'summary': r.get('body', ''),
                    'url': r.get('href', ''),
                    'source': 'arxiv',
                })
        return results
    except ImportError:
        logger.warning('ddgs 未安装，跳过 arxiv 搜索')
        return []
    except Exception as e:
        logger.warning(f'arxiv(ddgs) 搜索失败: {e}')
        return []


def search_hackernews(query: str = '', top_n: int = 10) -> list[dict]:
    """搜 HackerNews — 如果不搜特定词就拉热榜"""
    try:
        if query:
            # HN 搜索（Algolia API，免费）
            url = 'https://hn.algolia.com/api/v1/search'
            resp = requests.get(url, params={'query': query, 'hitsPerPage': top_n}, timeout=10)
            if resp.status_code != 200:
                return []
            hits = resp.json().get('hits', [])
        else:
            # 热榜
            top_ids = requests.get(f'{HN_API}/topstories.json', timeout=10).json()[:top_n]
            hits = []
            for tid in top_ids:
                item = requests.get(f'{HN_API}/item/{tid}.json', timeout=10).json()
                if item:
                    hits.append(item)

        results = []
        for item in hits:
            results.append({
                'title': item.get('title', '').strip(),
                'summary': f"{item.get('score', 0)} points, {item.get('descendants', 0)} comments",
                'url': item.get('url', f"https://news.ycombinator.com/item?id={item.get('objectID', item.get('id', ''))}"),
                'source': 'hackernews',
            })
        return results
    except Exception as e:
        logger.warning(f'HN 搜索失败: {e}')
        return []


def search_web(query: str, max_results: int = 5) -> list[dict]:
    """通用网页搜索（ddgs）"""
    try:
        from ddgs import DDGS
        with DDGS() as ddgs:
            results = list(ddgs.text(query, max_results=max_results))
        return [
            {
                'title': r.get('title', ''),
                'summary': r.get('body', ''),
                'url': r.get('href', ''),
                'source': 'web',
            }
            for r in results
        ]
    except ImportError:
        logger.warning('ddgs 未安装，跳过网页搜索')
        return []
    except Exception as e:
        logger.warning(f'网页搜索失败: {e}')
        return []


def search_github_trending(language: str = '') -> list[dict]:
    """GitHub trending（非官方，从 JSON endpoint 拉）"""
    try:
        url = 'https://api.github.com/search/repositories'
        params = {
            'q': f'created:>={_days_ago(7)}' + (f' language:{language}' if language else ''),
            'sort': 'stars',
            'order': 'desc',
            'per_page': 5,
        }
        resp = requests.get(url, params=params, headers={'Accept': 'application/vnd.github.v3+json'}, timeout=10)
        if resp.status_code != 200:
            return []
        items = resp.json().get('items', [])
        results = []
        for item in items:
            results.append({
                'title': f"{item.get('full_name', '')}: {item.get('description', '')}",
                'summary': f"Stars: {item.get('stargazers_count', 0)}, language: {item.get('language', 'unknown')}",
                'url': item.get('html_url', ''),
                'source': 'github',
            })
        return results
    except Exception as e:
        logger.warning(f'GitHub 搜索失败: {e}')
        return []


def _days_ago(n: int) -> str:
    import datetime as _dt
    d = _dt.datetime.now() - _dt.timedelta(days=n)
    return d.strftime('%Y-%m-%d')




def fetch_url(url: str) -> str:
    """抓取网页内容，提取正文，返回纯文本。最多 3000 字符。"""
    try:
        import trafilatura
        resp = requests.get(url, timeout=15, headers={
            'User-Agent': 'Mozilla/5.0 (compatible; DailyNote/1.0)',
        })
        if resp.status_code != 200:
            return f'无法访问 ({resp.status_code})'

        text = trafilatura.extract(resp.text,
                                   include_comments=False,
                                   include_tables=False,
                                   output_format='txt')
        if not text:
            return '未提取到正文内容'

        return text[:3000]
    except ImportError:
        return 'trafilatura 未安装，无法抓取网页'
    except Exception as e:
        return f'抓取失败: {e}'
