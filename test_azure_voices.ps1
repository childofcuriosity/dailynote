$dest = "E:\azure_tts_demo"
New-Item -ItemType Directory -Force -Path $dest | Out-Null

# 从环境变量读取 key，防止泄露：
#   $env:AZURE_SPEECH_KEY = "你的key"
$key = $env:AZURE_SPEECH_KEY
if (-not $key) {
    Write-Host "请先设置环境变量 AZURE_SPEECH_KEY" -ForegroundColor Red
    exit 1
}

$region = "eastasia"
$text = "你好呀，我是你的语音助手。今天天气真好，想不想一起出去散散步喝杯奶茶呢？"

# All Dragon HD female voices
$voices = @(
    "zh-CN-Xiaochen:DragonHDFlashLatestNeural",
    "zh-CN-Xiaohan:DragonHDFlashLatestNeural",
    "zh-CN-Xiaoke:DragonHDFlashLatestNeural",
    "zh-CN-Xiaoqi:DragonHDFlashLatestNeural",
    "zh-CN-Xiaoshuang:DragonHDFlashLatestNeural",
    "zh-CN-Xiaoxiao:DragonHDFlashLatestNeural",
    "zh-CN-Xiaoxiao2:DragonHDFlashLatestNeural",
    "zh-CN-Xiaoyi:DragonHDFlashLatestNeural",
    "zh-CN-Xiaoyou:DragonHDFlashLatestNeural",
    "zh-CN-Xiaoyu:DragonHDFlashLatestNeural"
)

$headers = @{
    'Ocp-Apim-Subscription-Key' = $key
    'Content-Type' = 'application/ssml+xml'
    'X-Microsoft-OutputFormat' = 'audio-24khz-160kbitrate-mono-mp3'
}

$i = 1
foreach ($voice in $voices) {
    $short = ($voice -replace 'zh-CN-','') -replace ':DragonHDFlashLatestNeural',''
    $out = "$dest\$i-$short.mp3"
    $i++
    Write-Host "$short"

    $body = "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='zh-CN'><voice name='$voice'>$text</voice></speak>"

    try {
        $r = Invoke-WebRequest -Uri "https://$region.tts.speech.microsoft.com/cognitiveservices/v1" -Method Post -Headers $headers -Body $body -TimeoutSec 15
        [IO.File]::WriteAllBytes($out, $r.Content)
        Write-Host "  OK"
    } catch {
        Write-Host "  FAILED"
    }
}

Write-Host ""
Write-Host "Done: $dest"
explorer $dest
