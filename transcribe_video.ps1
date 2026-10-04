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

    throw 'ffmpeg.exe was not found. Install FFmpeg and add it to PATH.'
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

    throw 'Dart SDK was not found. Install Flutter and add flutter/dart to PATH.'
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

    throw 'No readable SenseVoice model found. Run .\download_model.ps1. If DailyNote has locked the model, close it and retry.'
}

function Get-AvailableOutputPair(
    [string]$Directory,
    [string]$BaseName,
    [bool]$Overwrite
) {
    $number = 1
    while ($true) {
        $suffix = if ($number -eq 1) { '' } else { "_$number" }
        $srt = Join-Path $Directory "${BaseName}_subtitles${suffix}.srt"
        $txt = Join-Path $Directory "${BaseName}_transcript${suffix}.txt"
        if ($Overwrite -or
            ((-not (Test-Path -LiteralPath $srt)) -and
             (-not (Test-Path -LiteralPath $txt)))) {
            return @($srt, $txt)
        }
        $number += 1
    }
}

if (-not (Test-Path -LiteralPath $VideoPath -PathType Leaf)) {
    throw "Video file does not exist: $VideoPath"
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
        throw 'Missing .dart_tool\package_config.json and Flutter was not found. Run flutter pub get first.'
    }
    Write-Host 'First run: running flutter pub get...'
    Push-Location $projectRoot
    try {
        & $flutter.Source pub get
    } finally {
        Pop-Location
    }
    if ($LASTEXITCODE -ne 0) {
        throw 'flutter pub get failed.'
    }
}

$packageData = Get-Content -Raw -Encoding UTF8 $packageConfig | ConvertFrom-Json
$windowsPackage = $packageData.packages |
    Where-Object { $_.name -eq 'sherpa_onnx_windows' } |
    Select-Object -First 1
if (-not $windowsPackage) {
    throw 'sherpa_onnx_windows was not found. Run flutter pub get.'
}

$packageUri = [System.Uri]$windowsPackage.rootUri
if (-not $packageUri.IsFile) {
    throw "Cannot resolve sherpa_onnx_windows path: $($windowsPackage.rootUri)"
}
$sherpaDllDirectory = Join-Path $packageUri.LocalPath 'windows'
foreach ($dllName in @('sherpa-onnx-c-api.dll', 'onnxruntime.dll')) {
    if (-not (Test-Path -LiteralPath (Join-Path $sherpaDllDirectory $dllName) -PathType Leaf)) {
        throw "Missing native library: $dllName. Run flutter pub get."
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
    Write-Host "Video: $resolvedVideo"
    Write-Host 'Extracting audio...'
    & $ffmpeg -hide_banner -nostdin -y -i $resolvedVideo -map '0:a:0' -vn `
        -ac 1 -ar 16000 -c:a pcm_s16le $audioPath
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $audioPath)) {
        throw 'Audio extraction failed. Check that the video contains a readable audio track.'
    }

    Write-Host 'Transcribing offline with SenseVoice...'
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
        throw "SenseVoice failed with exit code: $LASTEXITCODE"
    }
    if (-not (Test-Path -LiteralPath $srtPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $txtPath -PathType Leaf)) {
        throw 'Transcription finished but no subtitle file was created.'
    }

    Write-Host ''
    Write-Host 'Done:'
    Write-Host "  Subtitles: $srtPath"
    Write-Host "  Transcript: $txtPath"
} finally {
    $env:PATH = $oldPath
    if (Test-Path -LiteralPath $workDirectory) {
        $resolvedWorkDirectory = (Resolve-Path -LiteralPath $workDirectory).Path
        if ($resolvedWorkDirectory.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $resolvedWorkDirectory -Recurse -Force
        }
    }
}
