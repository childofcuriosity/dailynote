# 下载 sherpa-onnx 语音模型：Silero VAD + SenseVoice（中英日韩粤）
# SenseVoice int8 ~200MB | silero_vad ~2MB

$dest = Join-Path $PSScriptRoot "assets\models"

Write-Host "Cleaning old model files..."
Remove-Item -Path "$dest\*.onnx" -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$dest\tokens.txt" -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$dest\*.tar.bz2" -Force -ErrorAction SilentlyContinue

Write-Host "Creating directory: $dest"
New-Item -ItemType Directory -Force -Path $dest | Out-Null

# ===== 1. Silero VAD (~2MB) =====
Write-Host "Downloading silero_vad.onnx (~2MB)..."
$vadUrl = "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx"
try {
    Invoke-WebRequest -Uri $vadUrl -OutFile "$dest\silero_vad.onnx" -TimeoutSec 60
} catch {
    Write-Host "Invoke-WebRequest failed, trying curl..."
    curl -L -o "$dest\silero_vad.onnx" $vadUrl
}

# ===== 2. SenseVoice int8 (~200MB) =====
Write-Host "Downloading SenseVoice int8 (~200MB)..."
$senseUrl = "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17.tar.bz2"
$tarFile = "$dest\sensevoice.tar.bz2"

try {
    Invoke-WebRequest -Uri $senseUrl -OutFile $tarFile -TimeoutSec 600
} catch {
    Write-Host "Invoke-WebRequest failed, trying curl..."
    curl -L -o $tarFile $senseUrl
}

Write-Host "Extracting SenseVoice..."
tar -xjf $tarFile -C $dest
Remove-Item $tarFile

# Move files out of subdirectory
$subdir = Get-ChildItem -Directory $dest | Where-Object { $_.Name -like "*sense*" } | Select-Object -First 1
if ($subdir) {
    Write-Host "Moving files from $($subdir.Name)..."
    Get-ChildItem -Path $subdir.FullName | Move-Item -Destination $dest -Force
    Remove-Item -Recurse $subdir.FullName
}

Write-Host ""
Write-Host "Done! Model files:"
Get-ChildItem -Path $dest -Include *.onnx,*.txt | ForEach-Object {
    $sizeMB = [math]::Round($_.Length / 1MB, 1)
    Write-Host "  $($_.Name) ($sizeMB MB)"
}
