param(
    [switch]$Clean,
    [int]$Jobs = [Math]::Max(1, [Environment]::ProcessorCount)
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$ffmpegRoot = Join-Path $repoRoot 'ffmpeg'
$buildRoot = Join-Path $repoRoot 'build\ffmpeg-audio'
$installRoot = Join-Path $buildRoot 'install'
$bash = 'C:\msys64\usr\bin\bash.exe'
$usrBin = 'C:\msys64\usr\bin'
$mingwBin = 'C:\msys64\mingw64\bin'

function Test-Tool {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Missing required tool or file: $Path"
    }
}

Test-Tool $ffmpegRoot
Test-Tool (Join-Path $ffmpegRoot 'configure')
Test-Tool $bash
Test-Tool (Join-Path $mingwBin 'gcc.exe')
Test-Tool (Join-Path $mingwBin 'pkg-config.exe')
$make = (Get-Command make -ErrorAction Stop).Source
$nasm = (Get-Command nasm -ErrorAction Stop).Source
$perl = (Get-Command perl -ErrorAction Stop).Source
Test-Tool $make
Test-Tool $nasm
Test-Tool $perl

Write-Host "[1/4] Preparing MSYS2 environment..."
$env:PATH = "$mingwBin;$usrBin;$env:PATH"
$env:PKG_CONFIG_PATH = (Join-Path $mingwBin 'lib\pkgconfig')
$env:MSYSTEM = 'MINGW64'
$env:MSYS2_PATH_TYPE = 'inherit'

foreach ($pkg in @('opus', 'lame')) {
    Write-Host "[2/4] Checking pkg-config package: $pkg"
    & $bash -lc "export MSYSTEM=MINGW64; export PATH=/mingw64/bin:`$PATH; export PKG_CONFIG_PATH=/mingw64/lib/pkgconfig; pkg-config --exists $pkg"
    if ($LASTEXITCODE -ne 0) {
        throw "Missing pkg-config package: $pkg"
    }
}

if ($Clean -and (Test-Path -LiteralPath $buildRoot)) {
    Remove-Item -LiteralPath $buildRoot -Recurse -Force
}

New-Item -ItemType Directory -Force -Path $buildRoot, $installRoot | Out-Null

$env:REPO_ROOT = $repoRoot
$env:FFMPEG_ROOT = $ffmpegRoot
$env:BUILD_ROOT = $buildRoot
$env:INSTALL_ROOT = $installRoot
$env:JOBS = $Jobs.ToString()

$bashScript = @'
set -euo pipefail

repo_root="$(cygpath -u "$REPO_ROOT")"
build_root="$(cygpath -u "$BUILD_ROOT")"
install_root="$(cygpath -u "$INSTALL_ROOT")"
ffmpeg_root="$(cygpath -u "$FFMPEG_ROOT")"

log() {
  printf '[%(%H:%M:%S)T] %s\n' -1 "$*"
}

mkdir -p "$build_root" "$install_root"
cd "$build_root"

export PATH=/mingw64/bin:$PATH
export PKG_CONFIG_PATH=/mingw64/lib/pkgconfig
export MSYSTEM=MINGW64

log "Starting FFmpeg configure"
"$ffmpeg_root/configure" \
  --prefix="$install_root" \
  --arch=x86_64 \
  --target-os=mingw32 \
  --disable-everything \
  --disable-autodetect \
  --disable-debug \
  --disable-doc \
  --disable-ffplay \
  --disable-ffprobe \
  --disable-avdevice \
  --disable-swscale \
  --disable-filters \
  --enable-small \
  --enable-gpl \
  --enable-protocol=file \
  --enable-protocol=pipe \
  --enable-parser=aac \
  --enable-parser=aac_latm \
  --enable-parser=flac \
  --enable-parser=mpegaudio \
  --enable-parser=opus \
  --enable-bsf=aac_adtstoasc \
  --enable-decoder=aac \
  --enable-decoder=aac_latm \
  --enable-decoder=flac \
  --enable-decoder=mp3 \
  --enable-decoder=mp3float \
  --enable-decoder=opus \
  --enable-decoder=pcm_alaw \
  --enable-decoder=pcm_f32le \
  --enable-decoder=pcm_f64le \
  --enable-decoder=pcm_mulaw \
  --enable-decoder=pcm_s16le \
  --enable-decoder=pcm_s24le \
  --enable-decoder=pcm_s32le \
  --enable-decoder=pcm_u8 \
  --enable-encoder=aac \
  --enable-encoder=flac \
  --enable-encoder=libmp3lame \
  --enable-encoder=libopus \
  --enable-libopus \
  --enable-libmp3lame \
  --enable-demuxer=aac \
  --enable-demuxer=flac \
  --enable-demuxer=mp3 \
  --enable-demuxer=mov \
  --enable-demuxer=ogg \
  --enable-demuxer=wav \
  --enable-demuxer=matroska \
  --enable-muxer=adts \
  --enable-muxer=flac \
  --enable-muxer=ipod \
  --enable-muxer=matroska \
  --enable-muxer=mov \
  --enable-muxer=mp3 \
  --enable-muxer=ogg \
  --enable-muxer=opus \
  --enable-muxer=wav

log "Starting make -j${JOBS:-1}"
make -j"${JOBS:-1}"

log "Starting make install"
make install

log "Build finished"
'@

$scriptPath = Join-Path $buildRoot 'build_ffmpeg_audio.sh'
Set-Content -LiteralPath $scriptPath -Value $bashScript -Encoding Ascii

$scriptUnixPath = & $bash -lc "cygpath -u '$scriptPath'"
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($scriptUnixPath)) {
    throw "Failed to convert script path for bash: $scriptPath"
}

Write-Host "[3/4] Running FFmpeg build script..."
& $bash $scriptUnixPath
Write-Host "[4/4] Done."
