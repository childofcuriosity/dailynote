# 客户端运行
创建：
flutter create .

首次运行前：
1. 复制 `lib/services/secrets.example.dart` 为 `lib/services/secrets.dart` 并填入你的配置（API Key 等，不会提交）
2. 下载语音模型（SenseVoice ~200MB + Silero VAD）：
```
.\download_model.ps1
```

[Environment]::SetEnvironmentVariable("NO_PROXY", "localhost,127.0.0.1,*.local", "User")

运行：
flutter run -d windows

发行版编译：
```
# Windows 桌面版
flutter build windows
# Android（连上手机或模拟器）
flutter build apk
```


# 远程部署服务器：
cd agent 
setx VPS_HOST "root@你的服务器IP:/root/agent/"   （服务器地址从环境变量读取）
.\deploy.bat        

# 本地git:
git add -A
git commit -m ""

# 功能
手机和ai聊天的日记向app。


