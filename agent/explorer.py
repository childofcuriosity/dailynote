"""Search and fetch content from multiple public sources."""
import logging
import time
import urllib.parse
import requests
from datetime import datetime

logger = logging.getLogger(__name__)

# The arxiv API is friendly and requires no key
ARXIV_API = 'http://export.arxiv.org/api/query'

# HackerNews
HN_API = 'https://hacker-news.firebaseio.com/v0'


def search_arxiv(query: str, max_results: int = 5) -> list[dict]:
    """Search arXiv through its API, falling back to ddgs."""
    try:
        import xml.etree.ElementTree as ET
        ns = {'atom': 'http://www.w3.org/2005/Atom'}
        # Direct connections from within China occasionally jitter; retry once
        for attempt in range(2):
            try:
                resp = requests.get('https://export.arxiv.org/api/query', params={
                    'search_query': f'all:{query}',
                    'max_results': max_results,
                }, timeout=30)
                break
            except Exception:
                if attempt == 1:
                    raise
                time.sleep(2)
        if resp.status_code == 200:
            root = ET.fromstring(resp.text)
            results = []
            for entry in root.findall('atom:entry', ns):
                title = ' '.join(entry.findtext('atom:title', '', ns).split())
                summary = ' '.join(entry.findtext('atom:summary', '', ns).split())[:400]
                url = entry.findtext('atom:id', '', ns)
                if title:
                    results.append({'title': title, 'summary': summary,
                                    'url': url, 'source': 'arxiv'})
            if results:
                return results
    except Exception as e:
        logger.warning('arXiv API failed: {0}'.format(e))

    # ddgs fallback
    try:
        try:
            from duckduckgo_search import DDGS  # 8.x package name
        except ImportError:
            from ddgs import DDGS  # Legacy package name
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
        logger.warning('ddgs is not installed; skipping arXiv search')
        return []
    except Exception as e:
        logger.warning('arXiv ddgs search failed: {0}'.format(e))
        return []


def search_hackernews(query: str = '', top_n: int = 10) -> list[dict]:
    """Search Hacker News, or fetch top stories without a query."""
    try:
        if query:
            # HN search (Algolia API, free)
            url = 'https://hn.algolia.com/api/v1/search'
            resp = requests.get(url, params={'query': query, 'hitsPerPage': top_n}, timeout=10)
            if resp.status_code != 200:
                return []
            hits = resp.json().get('hits', [])
        else:
            # Trending
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
        logger.warning('HN search failed: {0}'.format(e))
        return []


def search_web(query: str, max_results: int = 5) -> list[dict]:
    """Search the web with ddgs."""
    try:
        try:
            from duckduckgo_search import DDGS  # 8.x package name
        except ImportError:
            from ddgs import DDGS  # Legacy package name
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
        logger.warning('ddgs is not installed; skipping web search')
        return []
    except Exception as e:
        logger.warning('Web search failed: {0}'.format(e))
        return []


def search_github_trending(language: str = '') -> list[dict]:
    """Discover popular GitHub repositories."""
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
        logger.warning('GitHub search failed: {0}'.format(e))
        return []


def _days_ago(n: int) -> str:
    import datetime as _dt
    d = _dt.datetime.now() - _dt.timedelta(days=n)
    return d.strftime('%Y-%m-%d')




def fetch_url(url: str) -> str:
    """Fetch and extract up to 3,000 characters of page text."""
    try:
        import trafilatura
        resp = requests.get(url, timeout=15, headers={
            'User-Agent': 'Mozilla/5.0 (compatible; DailyNote/1.0)',
        })
        if resp.status_code != 200:
            return 'Unable to access ({0})'.format(resp.status_code)

        text = trafilatura.extract(resp.text,
                                   include_comments=False,
                                   include_tables=False,
                                   output_format='txt')
        if not text:
            return 'No article text could be extracted'

        return text[:3000]
    except ImportError:
        return 'trafilatura is not installed; unable to fetch page text'
    except Exception as e:
        return 'Fetch failed: {0}'.format(e)


def fetch_rendered(url: str, wait_ms: int = 5000) -> str:
    """Render a JavaScript page and extract up to 3,000 characters. Use after a plain fetch fails."""
    try:
        import glob
        import os
        import trafilatura
        from playwright.sync_api import sync_playwright

        # Use full Chromium to run headless (headless shell downloads extremely slowly in China; don't rely on it)
        chrome_candidates = glob.glob(
            os.path.expanduser('~/.cache/ms-playwright/chromium-*/chrome-linux64/chrome'))
        chrome_path = chrome_candidates[0] if chrome_candidates else None

        with sync_playwright() as p:
            browser = p.chromium.launch(
                headless=True,
                executable_path=chrome_path,
                args=['--no-sandbox', '--disable-dev-shm-usage'],
            )
            try:
                page = browser.new_page(
                    user_agent='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
                )
                page.goto(url, timeout=30000, wait_until='domcontentloaded')
                # Wait for JavaScript to asynchronously load the body
                page.wait_for_timeout(wait_ms)
                html = page.content()
            finally:
                browser.close()

        text = trafilatura.extract(html,
                                   include_comments=False,
                                   include_tables=False,
                                   output_format='txt')
        if not text:
            return 'No article text found after rendering'
        return text[:3000]
    except ImportError as e:
        return 'Missing dependency: {0}'.format(e)
    except Exception as e:
        return 'Rendered fetch failed: {0}'.format(e)
