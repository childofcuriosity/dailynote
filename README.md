# DailyNote

通过和 AI 聊天记录生活，由 AI 整理会话、提取记忆，并主动探索和分享新内容。

## 项目结构

- `lib/`：Flutter 客户端，包含聊天、会话、记忆和人格设置页面。
- `agent/`：Python Flask API 与后台 Agent，调用 DeepSeek，使用 SQLite 保存数据。
- `lib/services/voice/`：SenseVoice 离线识别、Silero VAD 和 Azure TTS。
- `tool/transcribe_video.dart`、`transcribe_video.ps1`：Windows 视频转字幕工具。

当前数据链路为 Flutter → Python HTTP API → SQLite / DeepSeek。`supabase_setup.sql` 和部分模型方法中的 Supabase 命名保留自早期实现。

## 客户端运行

安装 Flutter 后，在项目根目录执行：

```powershell
Copy-Item lib/services/secrets.example.dart lib/services/secrets.dart
flutter pub get
.\download_model.ps1
```

编辑 `lib/services/secrets.dart`，配置后端地址和 Azure 语音密钥。语音模型包含 SenseVoice（约 200 MB）和 Silero VAD。

```powershell
flutter run -d windows
flutter build windows
flutter build apk
```

如本地代理影响连接，可设置：

```powershell
[Environment]::SetEnvironmentVariable("NO_PROXY", "localhost,127.0.0.1,*.local", "User")
```

## 后端运行与部署

使用 Python 3.10 或更新版本，安装依赖及动态网页抓取使用的浏览器：

```powershell
python -m pip install -r agent/requirements.txt
python -m playwright install chromium
$env:DEEPSEEK_API_KEY = "你的 API Key"
python agent/main.py
```

Linux 浏览器运行依赖可通过 `python -m playwright install --with-deps chromium` 安装。API 默认监听 8080 端口，其他环境变量见 `agent/.env.example` 和 `agent/config.py`。直接运行 Python 时需自行设置环境变量；`.env` 由 systemd 服务的 `EnvironmentFile` 加载。

VPS 首次部署需配置 Python 依赖、Chromium、`agent/.env`、日志目录以及 `agent/dailynote-agent.service` 中的路径。已有服务可在 Windows 上更新代码：

```powershell
$env:VPS_HOST = "root@你的服务器IP:/root/agent/"
cd agent
.\deploy.bat
```

脚本上传 Python 文件并重启服务；依赖变化需另行在服务器安装。个人 `agent_soul.md` 留在运行环境，通过客户端人格设置页面管理。

## 视频转字幕

Windows 上安装 FFmpeg 并加入 PATH，完成客户端依赖和模型下载后执行：

```powershell
.\transcribe_video.ps1 "C:\Videos\example.mp4"
.\transcribe_video.ps1 "C:\Videos\example.mp4" "C:\Transcripts"
```

脚本用 FFmpeg 提取音轨，使用本地 SenseVoice 生成 SRT 字幕和纯文本。结果默认生成在视频旁边；已有同名文件时自动添加 `_2`、`_3` 后缀，需要覆盖时加 `-Force`。

## 代码与个人数据

Git 保存源代码、配置示例和依赖声明。以下内容由 `.gitignore` 排除，按需单独备份：

- `agent/data/`：默认 SQLite 数据库、聊天与探索记录、记忆及调试提示词。
- SQLite 数据库及其 WAL / journal 文件、运行日志和崩溃转储。
- `.env`、`lib/services/secrets.dart` 和个人 `agent/agent_soul.md`。
- 下载的语音模型、构建产物，以及工具生成的 `*_字幕*.srt`、`*_转写*.txt`。

探索时读取最近最多 100 条探索会话用于避免重复；记录保存在运行时数据库中。自定义数据库路径或导出其他格式的个人数据时，也应存放在仓库外或补充忽略规则。
