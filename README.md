# 运行
创建：
flutter create .
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

配置：
注册 DeepSeek + Supabase
在 Supabase SQL Editor 跑supabase_setup.sql这个文件
把 key 发给你，你填到 secrets.dart 打出 APK

远程部署：
agent\deploy.bat          

本地git:
git add .
git commit -m ""

结构：服务器主，app从
# 功能
手机和ai聊天的日记向app。


