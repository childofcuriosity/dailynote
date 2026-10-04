// Account-scoped UI language. The entry screen and public demo use English.
class AppLanguage {
  static bool isChinese = false;
  static String get locale => isChinese ? 'zh_CN' : 'en_US';
}

String tr(String english, [List<Object?> arguments = const []]) {
  var text = AppLanguage.isChinese ? (_chinese[english] ?? english) : english;
  for (var i = 0; i < arguments.length; i++) {
    text = text.replaceAll('{$i}', '${arguments[i]}');
  }
  return text;
}

const _chinese = <String, String>{
  "Explore sample entries and chat with AI. This demo is shared by all visitors. Please do not enter private information.":
      "体验示例日记与 AI 聊天。演示内容由所有访客共享，请勿填写个人隐私。",
  "Enter your password to access your diary and memories.": "输入密码，查看你的日记和记忆。",
  "Unable to connect. Please try again later.": "暂时无法连接服务，请稍后重试",
  "Welcome to DailyNote": "欢迎来到日记助手",
  "Choose an account to get started": "选择一个账户开始",
  "Enter DailyNote": "进入日记助手",
  "Signing in…": "正在进入…",
  "Public demo": "公共演示",
  "Personal account": "个人账户",
  "Password": "密码",
  "Write a message… (Enter for a new line, Ctrl+Enter to send)":
      "输入内容... (Enter换行, Ctrl+Enter发送)",
  "Archived: {0}": "已归档：{0}",
  "This creates a new conversation branch and keeps the original.":
      "将创建新对话（Fork），原对话保留。",
  "New branch created. The original conversation is preserved.":
      "已创建新分支（Fork），原对话保留",
  "AI will create titles and summaries and extract memories.":
      "AI 将自动生成标题、摘要并提取记忆",
  "Listening: {0}": "正在听: {0}",
  "Loading speech model…": "正在加载语音模型...",
  "Could not create branch: {0}": "Fork 失败：{0}",
  "AI is thinking…": "AI 正在思考...",
  "AI is replying…": "AI 正在回复...",
  "Branch and send": "Fork 并发送",
  "Could not archive: {0}": "归档失败：{0}",
  "AI is replying": "AI 正在回复",
  "Error: {0}": "出错了：{0}",
  "Archive this conversation": "归档这段对话",
  "Listening…": "正在听...",
  "Start a conversation": "开始对话吧",
  "Edit message": "编辑消息",
  "Reasoning and tools": "思考过程",
  "New conversation": "新对话",
  "Something went wrong": "出错了",
  "Copied": "已复制",
  "Cancel": "取消",
  "Edit": "编辑",
  "Title": "标题",
  "Summary": "摘要",
  "Notes": "备注",
  "Save": "保存",
  "Archive": "归档",
  "Stay": "留下",
  "Leave": "离开",
  "Delete “{0}” and all its messages?\nThis cannot be undone.":
      "删除「{0}」及其所有消息？\n此操作不可撤销。",
  "{0} selected": "已选 {0} 项",
  "DailyNote · Public demo": "日记助手 · 公共演示",
  "DailyNote · Personal": "日记助手 · 个人",
  "Show AI discoveries": "显示 AI 发现",
  "Hide AI discoveries": "隐藏 AI 发现",
  "Show archived entries": "显示已归档",
  "Hide archived entries": "隐藏已归档",
  "No diary entries yet": "还没有日记",
  "Manage tags": "管理标签",
  "New tag name": "新标签名",
  "Pin to favorites": "精选置顶",
  "Confirm deletion": "确认删除",
  "Switch account": "切换账户",
  "Show all": "显示全部",
  "Favorites only": "只看精选",
  "Hide hidden entries": "隐藏归档",
  "Memories": "记忆管理",
  "Select entries": "批量选择",
  "Close": "关闭",
  "Hide": "隐藏",
  "Tags": "标签",
  "Delete": "删除",
  "Select all": "全选",
  "Retry": "重试",
  "Favorite": "收藏",
  "kebab-case, e.g. prefer-short-replies": "kebab-case，如 dislike-morning-msg",
  "No memories yet. AI can extract them when you archive a conversation.":
      "还没有记忆，归档对话后 AI 会自动提取",
  "Used to find relevant memories": "用于索引匹配",
  "Self-correction": "自我纠正",
  "Edit memory": "编辑记忆",
  "One-line summary": "一行摘要",
  "Full content": "完整内容",
  "Add memory": "添加记忆",
  "Name": "标识名",
  "Fact": "事实",
  "Feedback": "偏好",
  "Observation": "观察",
  "Type": "类型",
  "Add": "添加",
  "Write the AI's behavior guidelines…": "写 AI 的行为准则...",
  "Saved": "已保存",
  "DailyNote": "日记助手",
  "Sign-in failed": "登录失败",
  "Split into {0} diary entries": "已拆分为 {0} 条日记",
  "A reply is in progress. Leave this conversation?": "离开会丢失本次回复，确定要离开吗？",
  "Any special instructions? (optional)": "有什么特别要求？（选填）",
  "For example: #important #todo": "如：#重要 #待办",
};
