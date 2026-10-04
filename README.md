# DailyNote | An Agent with Long-Term Memory and Tool Use

**Personal open-source project · 2026**

[GitHub](https://github.com/childofcuriosity/dailynote) · [Live demo](http://164.152.167.211:8082/)

## Motivation

One practical direction for agent self-improvement is managing memory and personalization at the system level. My starting point was the way coding-agent workflows, such as those built around Claude Code, combine tool use and persistent instructions to adapt to user preferences and project conventions. DailyNote applies that idea through long-term memories, explicit behavior requirements, and an owner-written `agent_soul.md` file.

I already had a habit of keeping a diary and discussing everyday life with AI. A personal diary app met a real need for convenience while providing a useful setting to explore this approach: preferences and context accumulate over time, and their value becomes visible in the experience of using the assistant.

## Implementation

DailyNote has two user-facing modes, **user-initiated conversation** and **periodic exploration**, plus **automatic archiving** in the background. Every mode receives the account owner's behavior guidelines, basic instructions, a long-term memory index, and an index of archived user conversations. Each mode then adds the context and tools needed for its task:

| Mode | Additional context | Tools and outcome |
| --- | --- | --- |
| Conversation | The current chat history | Retrieve relevant details, search when needed, manage memories, and reply to the user |
| Periodic exploration | Summaries of up to 100 previous discoveries, with a short text fallback when a summary is unavailable | Search public sources, avoid repeated discoveries, and share one interesting finding |
| Archiving | The complete conversation with numbered messages | Use only memory retrieval/management and archive submission to extract memories and group messages into topic-based entries |

Long-term memories and archived conversations each have a compact index entry and full content. The agent starts with the indexes and calls retrieval tools when it needs more detail. It can create, revise, and delete memories, update conversation titles and summaries, and submit archive segments. The backend checks that the proposed segments cover every message exactly once before creating the archived entries.

Memories distinguish facts and observations from feedback and self-corrections. The latter become behavioral guidance in later interactions, so the assistant can carry forward what it has learned about the user's preferences. This implements self-improvement at the **agent system level**, through stored context and tool-mediated updates. Its practical outcome is a more personalized experience, judged by how useful the assistant feels to its owner; the underlying model weights stay unchanged.

## Try it

Open the [web demo](http://164.152.167.211:8082/) and choose **Public demo**. The interface, sample content, prompts, and AI output are in English. Two existing proactive discoveries are available alongside the example diary entries. The password-protected personal account retains its Chinese interface and content.

Both accounts explore every **10 days** and scan for automatic archiving every **4 hours**. The public account is shared by visitors, so use it with demonstration content.

## Technical appendix

The setup, architecture, deployment, testing, and data-management instructions are retained below.

### Accounts and languages

The opening dialog offers two accounts:

| Account | Access | Language | Data |
| --- | --- | --- | --- |
| Public demo | No password | English UI, prompts, and AI output | Shared synthetic examples and visitor conversations |
| Personal | Password required | Chinese UI, prompts, and AI output | Existing personal diary, memories, and behavior settings |

Use the account button to sign out and switch. Refreshing the page returns to the account dialog. All visitors share the public demo; entries there are visible to other visitors.

Each account has its own SQLite database, behavior guidelines, debug prompts, and persistent schedule. Backend requests and worker threads bind to the selected account. The personal password is checked on the server using a Werkzeug hash. Bearer sessions expire after 12 hours; all data endpoints require a session, and admin endpoints are restricted to the personal account.

### How the agent works

1. **Conversation:** the backend combines account guidelines, the current conversation, and compact indexes of archived conversations and memories. The model can load full records when an index is insufficient.
2. **Memory:** facts and observations supply context; feedback and self-corrections guide subsequent responses. Tools create, revise, and delete these memories. This is application-level adaptation through persistent context; model weights stay unchanged.
3. **Archive:** the agent extracts useful memories and groups messages by topic. It validates that every message belongs to exactly one segment, then copies messages into titled entries while preserving the original conversation.
4. **Exploration:** the agent searches the web, arXiv, Hacker News, and GitHub for one relevant discovery. It consults up to 100 prior discoveries to avoid repeating itself, then archives the result for future retrieval.

Both accounts run proactive exploration **every 10 days** and scan for automatic archiving **every 4 hours**. Archive candidates are visible user conversations created before today, idle for at least five minutes, and changed since their last archive. Each account persists its schedule across restarts. A manual exploration resets that account's next exploration time. Configure the interval with `EXPLORE_INTERVAL_DAYS`.

Memory is intended to make the companion more useful in everyday use. The owner can inspect and edit memories and behavior guidelines directly.

### Code map

| Path | Responsibility |
| --- | --- |
| `lib/pages/` | Account selection, diary list, chat, memories, and behavior settings |
| `lib/services/api_service.dart` | Authenticated API calls and session lifecycle |
| `lib/services/l10n.dart` | English UI text with Chinese translations for the personal account |
| `agent/auth.py` | Password validation, sessions, and account access |
| `agent/account_context.py` | Thread-local account selection and storage paths |
| `agent/agent.py` | Reply loop, tool execution, exploration, and archiving |
| `agent/ai_client.py` | Model requests, English prompts, and tool schemas |
| `agent/i18n.py`, `agent/locales/zh.json` | Account-specific prompt and tool-description language |
| `agent/database.py` | SQLite storage and persistent scheduling state |
| `agent/demo_data.py` | Idempotent seeding of fictional English examples |
| `agent/explorer.py` | Search sources and plain/browser-rendered page extraction |
| `deploy/nginx-web.conf.example` | Same-origin web hosting and API proxy |

`supabase_setup.sql` and model methods named `fromSupabase` / `toSupabase` remain from an earlier storage implementation. The active backend uses SQLite.

### Run the backend

Use Python 3.10 or newer:

```powershell
python -m pip install -r agent/requirements.txt
python -m playwright install chromium
$env:DEEPSEEK_API_KEY = "your-api-key"
python agent/main.py
```

On Linux, `python -m playwright install --with-deps chromium` also installs browser dependencies. The API defaults to port `8081`. Settings are documented in `agent/.env.example` and `agent/config.py`. Direct Python execution reads environment variables; the provided systemd service loads `.env` through `EnvironmentFile`.

Create the personal password hash interactively so the password stays out of source code and command history:

```powershell
python -c "from pathlib import Path; from getpass import getpass; from werkzeug.security import generate_password_hash; p=Path('agent/data/personal_password.hash'); p.parent.mkdir(parents=True,exist_ok=True); p.write_text(generate_password_hash(getpass('Personal password: ')),encoding='utf-8')"
```

Alternatively, set `PERSONAL_PASSWORD_HASH`. Personal sign-in is unavailable until a hash is configured. First startup seeds the demo once; later restarts retain its data.

### Build and serve the web client

The web app is the supported client. Recording, headset controls, and spoken replies are disabled. Native speech code remains available for future reuse; speech models and API secrets are excluded from the web bundle.

```powershell
flutter pub get
flutter build web --no-web-resources-cdn
```

Serve `build/web/` through Nginx using `deploy/nginx-web.conf.example`. The browser calls `/api` on the same origin; Nginx forwards `/api/` to `127.0.0.1:8081/`, removing the prefix. Use this arrangement locally or on a server to avoid cross-origin configuration. An explicit API address can be supplied with `--dart-define=API_BASE_URL=...`; a different origin requires appropriate CORS configuration.

The current deployment is available at [the live demo](http://164.152.167.211:8082/). It uses HTTP; the personal password and session token therefore lack transport encryption. Configure HTTPS before using it over an untrusted network.

For a new VPS installation, configure Python dependencies, Chromium, `.env`, log directories, Nginx, and the paths in `agent/dailynote-agent.service`. For subsequent backend updates from Windows:

```powershell
$env:VPS_HOST = "root@your-server:/root/agent/"
cd agent
.\deploy.bat
```

The script uploads Python sources and locale resources, then restarts the service. Install changed dependencies separately. Upload a fresh `build/web/` whenever the client changes. Keep databases, passwords, `.env`, and personal behavior settings in place during deployment.

### Verify changes

```powershell
python -m unittest discover -s agent -p test_accounts.py -v
flutter analyze
flutter test
flutter build web --no-web-resources-cdn
```

The offline tests cover account isolation, authentication, independent schedules, language selection, prompt content, archive message coverage instructions, and the text-only web UI. `agent/test_archive.py` is a separate live integration script and creates data in the selected running account; it is not part of the offline suite.

### Optional local video transcription

The Windows transcription tool runs independently of the web app. Install FFmpeg on `PATH`, run `flutter pub get` and `.\download_model.ps1`, then:

```powershell
.\transcribe_video.ps1 "C:\Videos\example.mp4"
.\transcribe_video.ps1 "C:\Videos\example.mp4" "C:\Transcripts"
```

It extracts audio with FFmpeg and uses local SenseVoice models to produce SRT subtitles and plain text. Outputs default to the video's directory. Existing names receive a numeric suffix unless `-Force` is supplied.

### Source control and private data

Git contains code, configuration examples, and dependency declarations. `.gitignore` excludes runtime databases, memories, conversations, exploration history, debug prompts, logs, secrets, behavior settings, downloaded models, and generated transcripts. Back up those separately.

Personal storage defaults to `agent/data/`; public demo storage is under `agent/data/demo/`. Chinese text in the two locale catalogs is intentional. Runtime personal content stays in its original language, and translating the demo does not translate personal records. Put custom database paths and exports outside the repository, or add matching ignore rules.
