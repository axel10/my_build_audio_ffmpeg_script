param(
    [switch]$Clean,
    [int]$Jobs = [Math]::Max(1, [Environment]::ProcessorCount),
    [string]$SdkRoot = 'D:\android-sdk'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$ffmpegRoot = Join-Path $repoRoot 'ffmpeg'
$buildRoot = Join-Path $repoRoot 'build\ffmpeg-android-arm64-v8a'
$installRoot = Join-Path $buildRoot 'install'
$bash = 'C:\msys64\usr\bin\bash.exe'
$mingwBin = 'C:\msys64\mingw64\bin'

function Test-Tool {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Missing required tool or file: $Path"
    }
}

function Get-LatestDirectory {
    param([string]$Path)

    $dirs = Get-ChildItem -LiteralPath $Path -Directory -ErrorAction Stop
    if (-not $dirs) {
        throw "No directories found under: $Path"
    }

    $versioned = foreach ($dir in $dirs) {
        try {
            [pscustomobject]@{
                Path    = $dir.FullName
                Version = [version]$dir.Name
            }
        } catch {
            [pscustomobject]@{
                Path    = $dir.FullName
                Version = [version]'0.0.0.0'
            }
        }
    }

    return ($versioned | Sort-Object Version -Descending | Select-Object -First 1).Path
}

Test-Tool $ffmpegRoot
Test-Tool (Join-Path $ffmpegRoot 'configure')
Test-Tool $bash
Test-Tool (Join-Path $mingwBin 'gcc.exe')
Test-Tool (Join-Path $mingwBin 'g++.exe')
Test-Tool $SdkRoot

$ndkRoot = Join-Path $SdkRoot 'ndk'
Test-Tool $ndkRoot

$selectedNdk = Get-LatestDirectory $ndkRoot
$ndkBin = Join-Path $selectedNdk 'toolchains\llvm\prebuilt\windows-x86_64\bin'
Test-Tool $ndkBin
Test-Tool (Join-Path $ndkBin 'clang.exe')
Test-Tool (Join-Path $ndkBin 'llvm-ar.exe')
Test-Tool (Join-Path $ndkBin 'llvm-nm.exe')
Test-Tool (Join-Path $ndkBin 'llvm-ranlib.exe')
Test-Tool (Join-Path $ndkBin 'llvm-strip.exe')

if ($Clean -and (Test-Path -LiteralPath $buildRoot)) {
    Remove-Item -LiteralPath $buildRoot -Recurse -Force
}

New-Item -ItemType Directory -Force -Path $buildRoot, $installRoot | Out-Null

$env:REPO_ROOT = $repoRoot
$env:FFMPEG_ROOT = $ffmpegRoot
$env:BUILD_ROOT = $buildRoot
$env:INSTALL_ROOT = $installRoot
$env:NDK_ROOT = $selectedNdk
$env:NDK_BIN = $ndkBin
$env:MINGW_BIN = $mingwBin
$env:JOBS = $Jobs.ToString()

$bashScript = @'
set -euo pipefail

repo_root="$(cygpath -u "$REPO_ROOT")"
build_root="$(cygpath -u "$BUILD_ROOT")"
install_root="$(cygpath -u "$INSTALL_ROOT")"
ffmpeg_root="$(cygpath -u "$FFMPEG_ROOT")"
ndk_root="$(cygpath -u "$NDK_ROOT")"
ndk_bin="$(cygpath -u "$NDK_BIN")"
mingw_bin="$(cygpath -u "$MINGW_BIN")"

log() {
  printf '[%(%H:%M:%S)T] %s\n' -1 "$*"
}

mkdir -p "$build_root" "$install_root"
cd "$build_root"

export PATH="$mingw_bin:$ndk_bin:$PATH"
export PKG_CONFIG=/bin/false

api_level=21
abi=arm64-v8a
tool_prefix=aarch64-linux-android${api_level}
sysroot="$ndk_root/toolchains/llvm/prebuilt/windows-x86_64/sysroot"
cc="${tool_prefix}-clang"
cxx="${tool_prefix}-clang++"
ar="llvm-ar"
nm="llvm-nm"
ranlib="llvm-ranlib"
strip="llvm-strip"

log "Starting FFmpeg configure for Android ${abi}"
configureArgs=(
  --prefix="$install_root"
  --arch=aarch64
  --cpu=armv8-a
  --target-os=android
  --enable-cross-compile
  --cross-prefix="${tool_prefix}-"
  --sysroot="$sysroot"
  --host-cc=clang
  --host-ld=clang
  --enable-pic
  --enable-shared
  --disable-static
  --disable-programs
  --disable-doc
  --disable-debug
  --disable-ffmpeg
  --disable-ffplay
  --disable-ffprobe
  --disable-avdevice
  --disable-autodetect
  --disable-filters
  --enable-filter=aresample
  --enable-small
  --enable-gpl
  --enable-protocol=file
  --enable-protocol=pipe
  --enable-parser=aac
  --enable-parser=aac_latm
  --enable-parser=flac
  --enable-parser=mpegaudio
  --enable-parser=opus
  --enable-bsf=aac_adtstoasc
  --enable-decoder=aac
  --enable-decoder=aac_latm
  --enable-decoder=flac
  --enable-decoder=mjpeg
  --enable-decoder=mp3
  --enable-decoder=mp3float
  --enable-decoder=opus
  --enable-decoder=pcm_alaw
  --enable-decoder=pcm_f32le
  --enable-decoder=pcm_f64le
  --enable-decoder=pcm_mulaw
  --enable-decoder=pcm_s16le
  --enable-decoder=pcm_s24le
  --enable-decoder=pcm_s32le
  --enable-decoder=pcm_u8
  --enable-encoder=aac
  --enable-encoder=flac
  --enable-encoder=mjpeg
  --enable-encoder=opus
  --enable-demuxer=aac
  --enable-demuxer=flac
  --enable-demuxer=mp3
  --enable-demuxer=mov
  --enable-demuxer=ffmetadata
  --enable-demuxer=ogg
  --enable-demuxer=wav
  --enable-demuxer=matroska
  --enable-muxer=adts
  --enable-muxer=flac
  --enable-muxer=ipod
  --enable-muxer=matroska
  --enable-muxer=mov
  --enable-muxer=mp3
  --enable-muxer=ogg
  --enable-muxer=opus
  --enable-muxer=wav
  --cc="$cc"
  --cxx="$cxx"
  --ar="$ar"
  --nm="$nm"
  --ranlib="$ranlib"
  --strip="$strip"
)

"$ffmpeg_root/configure" "${configureArgs[@]}"

log "Starting make -j${JOBS:-1}"
make -j"${JOBS:-1}"

log "Starting make install"
make install

log "Android FFmpeg build finished"
'@

$scriptPath = Join-Path $buildRoot 'build_ffmpeg_android_arm64_v8a.sh'
Set-Content -LiteralPath $scriptPath -Value $bashScript -Encoding Ascii

$scriptUnixPath = & $bash -lc "cygpath -u '$scriptPath'"
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($scriptUnixPath)) {
    throw "Failed to convert script path for bash: $scriptPath"
}

Write-Host "[1/3] NDK: $selectedNdk"
Write-Host "[2/3] Running Android FFmpeg build script..."
& $bash $scriptUnixPath
Write-Host "[3/3] Done."
