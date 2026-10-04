$dest = "E:\azure_tts_demo"
New-Item -ItemType Directory -Force -Path $dest | Out-Null

# Read the key from environment variables to prevent leaking:
#   $env:AZURE_SPEECH_KEY = "your key"
$key = $env:AZURE_SPEECH_KEY
if (-not $key) {
    Write-Host "Set AZURE_SPEECH_KEY first" -ForegroundColor Red
    exit 1
}

$region = "eastasia"
$text = "Hello! I am your voice assistant. It is a lovely day. Would you like to go for a walk and get some tea?"

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
