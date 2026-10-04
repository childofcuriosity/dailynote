[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$VideoPath,

    [Parameter(Position = 1)]
    [string]$OutputDirectory,

    [switch]$Force
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function Find-FFmpeg {
    $command = Get-Command ffmpeg.exe -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    $candidates = @(
        'C:\Program Files (x86)\ACLOS\Cross\recorder-release\ffmpeg.exe',
        'C:\Program Files\ffmpeg\bin\ffmpeg.exe',
        'C:\ffmpeg\bin\ffmpeg.exe'
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }

    throw '没有找到 ffmpeg.exe。请先安装 FFmpeg，或把 ffmpeg.exe 加入 PATH。'
}

function Find-DartExe {
    $direct = Get-Command dart.exe -ErrorAction SilentlyContinue
    if ($direct -and $direct.Source.EndsWith('.exe')) {
        return $direct.Source
    }

    $dartCommand = Get-Command dart -ErrorAction SilentlyContinue
    if ($dartCommand) {
        $flutterBin = Split-Path -Parent $dartCommand.Source
        $bundledDart = Join-Path $flutterBin 'cache\dart-sdk\bin\dart.exe'
        if (Test-Path -LiteralPath $bundledDart -PathType Leaf) {
            return $bundledDart
        }
    }

    $knownDart = 'C:\tools\flutter\bin\cache\dart-sdk\bin\dart.exe'
    if (Test-Path -LiteralPath $knownDart -PathType Leaf) {
        return $knownDart
    }

    throw '没有找到 Dart SDK。请先安装 Flutter，并确保 flutter/dart 在 PATH 中。'
}

function Test-ReadableFile([string]$Path) {
    try {
        $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
        $stream = [System.IO.File]::Open(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            $share
        )
        $stream.Dispose()
        return $true
    } catch {
        return $false
    }
}

function Find-ReadableModelDirectory([string]$ProjectRoot) {
    $candidates = @(
        (Join-Path $ProjectRoot 'assets\models'),
        (Join-Path $ProjectRoot 'build\app\intermediates\flutter\release\flutter_assets\assets\models'),
        (Join-Path $ProjectRoot 'build\app\intermediates\flutter\debug\flutter_assets\assets\models'),
        (Join-Path $ProjectRoot 'build\windows\x64\runner\Release\data\flutter_assets\assets\models'),
        (Join-Path $ProjectRoot 'build\windows\x64\runner\Debug\data\flutter_assets\assets\models')
    )
    $required = @('model.int8.onnx', 'tokens.txt', 'silero_vad.onnx')

    foreach ($directory in $candidates) {
        $usable = $true
        foreach ($name in $required) {
            $file = Join-Path $directory $name
            if (-not (Test-Path -LiteralPath $file -PathType Leaf) -or
                -not (Test-ReadableFile $file)) {
                $usable = $false
                break
            }
        }
        if ($usable) {
            return $directory
        }
    }

    throw '没有找到可读取的 SenseVoice 模型。请先运行 .\download_model.ps1；如果 DailyNote 正在运行并锁定模型，请关闭它后重试。'
}

function Get-AvailableOutputPair(
    [string]$Directory,
    [string]$BaseName,
    [bool]$Overwrite
) {
    $number = 1
    while ($true) {
        $suffix = if ($number -eq 1) { '' } else { "_$number" }
        $srt = Join-Path $Directory "${BaseName}_字幕${suffix}.srt"
        $txt = Join-Path $Directory "${BaseName}_转写${suffix}.txt"
        if ($Overwrite -or
            ((-not (Test-Path -LiteralPath $srt)) -and
             (-not (Test-Path -LiteralPath $txt)))) {
            return @($srt, $txt)
        }
        $number += 1
    }
}

if (-not (Test-Path -LiteralPath $VideoPath -PathType Leaf)) {
    throw "视频文件不存在：$VideoPath"
}
$resolvedVideo = (Resolve-Path -LiteralPath $VideoPath).Path

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $resolvedOutputDirectory = Split-Path -Parent $resolvedVideo
} else {
    if (-not (Test-Path -LiteralPath $OutputDirectory)) {
        New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    }
    $resolvedOutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path
}

$projectRoot = $PSScriptRoot
$packageConfig = Join-Path $projectRoot '.dart_tool\package_config.json'
if (-not (Test-Path -LiteralPath $packageConfig -PathType Leaf)) {
    $flutter = Get-Command flutter -ErrorAction SilentlyContinue
    if (-not $flutter) {
        throw '缺少 .dart_tool\package_config.json，并且没有找到 Flutter。请先运行 flutter pub get。'
    }
    Write-Host '首次运行：正在执行 flutter pub get...'
    Push-Location $projectRoot
    try {
        & $flutter.Source pub get
    } finally {
        Pop-Location
    }
    if ($LASTEXITCODE -ne 0) {
        throw 'flutter pub get 失败。'
    }
}

$packageData = Get-Content -Raw -Encoding UTF8 $packageConfig | ConvertFrom-Json
$windowsPackage = $packageData.packages |
    Where-Object { $_.name -eq 'sherpa_onnx_windows' } |
    Select-Object -First 1
if (-not $windowsPackage) {
    throw '没有找到 sherpa_onnx_windows 依赖。请运行 flutter pub get。'
}

$packageUri = [System.Uri]$windowsPackage.rootUri
if (-not $packageUri.IsFile) {
    throw "无法解析 sherpa_onnx_windows 路径：$($windowsPackage.rootUri)"
}
$sherpaDllDirectory = Join-Path $packageUri.LocalPath 'windows'
foreach ($dllName in @('sherpa-onnx-c-api.dll', 'onnxruntime.dll')) {
    if (-not (Test-Path -LiteralPath (Join-Path $sherpaDllDirectory $dllName) -PathType Leaf)) {
        throw "缺少原生库：$dllName。请运行 flutter pub get。"
    }
}

$ffmpeg = Find-FFmpeg
$dartExe = Find-DartExe
$modelDirectory = Find-ReadableModelDirectory $projectRoot
$dartTool = Join-Path $projectRoot 'tool\transcribe_video.dart'
$baseName = [System.IO.Path]::GetFileNameWithoutExtension($resolvedVideo)
$outputs = Get-AvailableOutputPair $resolvedOutputDirectory $baseName $Force.IsPresent
$srtPath = $outputs[0]
$txtPath = $outputs[1]

$tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
$workDirectory = Join-Path $tempRoot ("dailynote-transcribe-" + [guid]::NewGuid().ToString('N'))
$audioPath = Join-Path $workDirectory 'audio.wav'
$oldPath = $env:PATH

New-Item -ItemType Directory -Path $workDirectory | Out-Null
try {
    Write-Host "视频：$resolvedVideo"
    Write-Host '正在提取音轨...'
    & $ffmpeg -hide_banner -nostdin -y -i $resolvedVideo -map '0:a:0' -vn `
        -ac 1 -ar 16000 -c:a pcm_s16le $audioPath
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $audioPath)) {
        throw '音轨提取失败；请确认视频包含可读取的音频。'
    }

    Write-Host '正在用 SenseVoice 离线识别...'
    $env:PATH = "$sherpaDllDirectory;$oldPath"
    & $dartExe "--packages=$packageConfig" $dartTool `
        $audioPath `
        (Join-Path $modelDirectory 'model.int8.onnx') `
        (Join-Path $modelDirectory 'tokens.txt') `
        (Join-Path $modelDirectory 'silero_vad.onnx') `
        $sherpaDllDirectory `
        $srtPath `
        $txtPath
    if ($LASTEXITCODE -ne 0) {
        throw "SenseVoice 识别失败，退出码：$LASTEXITCODE"
    }
    if (-not (Test-Path -LiteralPath $srtPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $txtPath -PathType Leaf)) {
        throw '识别结束，但没有生成字幕文件。'
    }

    Write-Host ''
    Write-Host '完成：'
    Write-Host "  字幕：$srtPath"
    Write-Host "  文稿：$txtPath"
} finally {
    $env:PATH = $oldPath
    if (Test-Path -LiteralPath $workDirectory) {
        $resolvedWorkDirectory = (Resolve-Path -LiteralPath $workDirectory).Path
        if ($resolvedWorkDirectory.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $resolvedWorkDirectory -Recurse -Force
        }
    }
}
