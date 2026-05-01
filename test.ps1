param(
    [string]$Root = $PSScriptRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path -LiteralPath $Root).Path
$ffmpegDir = Join-Path $repoRoot 'build\ffmpeg-audio\install\bin'
$ffmpeg = Join-Path $ffmpegDir 'ffmpeg.exe'
$ffprobe = Join-Path $ffmpegDir 'ffprobe.exe'
$input = Join-Path $repoRoot 'test.wav'
$outdir = Join-Path $repoRoot 'build\test-output'
$metaFile = Join-Path $outdir 'test.opus.ffmetadata'

function Test-File {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Missing file: $Path"
    }
}

function Read-UInt32BE {
    param(
        [byte[]]$Bytes,
        [int]$Offset
    )

    return ([uint32]$Bytes[$Offset]     -shl 24) -bor
           ([uint32]$Bytes[$Offset + 1] -shl 16) -bor
           ([uint32]$Bytes[$Offset + 2] -shl 8)  -bor
           ([uint32]$Bytes[$Offset + 3])
}

function Read-SynchsafeInt {
    param(
        [byte[]]$Bytes,
        [int]$Offset
    )

    return ([int]$Bytes[$Offset]     -shl 21) -bor
           ([int]$Bytes[$Offset + 1] -shl 14) -bor
           ([int]$Bytes[$Offset + 2] -shl 7)  -bor
           ([int]$Bytes[$Offset + 3])
}

function Escape-FfMetadataValue {
    param([string]$Value)

    $escaped = $Value -replace '\\', '\\\\'
    $escaped = $escaped -replace "`r", ''
    $escaped = $escaped -replace "`n", '\n'
    $escaped = $escaped -replace ';', '\;'
    $escaped = $escaped -replace '#', '\#'
    return $escaped
}

function Write-UInt32BE {
    param(
        [System.IO.BinaryWriter]$Writer,
        [uint32]$Value
    )

    $Writer.Write([byte](($Value -shr 24) -band 0xff))
    $Writer.Write([byte](($Value -shr 16) -band 0xff))
    $Writer.Write([byte](($Value -shr 8) -band 0xff))
    $Writer.Write([byte]($Value -band 0xff))
}

function Read-NulTerminatedString {
    param(
        [byte[]]$Bytes,
        [ref]$Offset,
        [System.Text.Encoding]$Encoding
    )

    $start = $Offset.Value
    $end = $start
    while ($end -lt $Bytes.Length -and $Bytes[$end] -ne 0) {
        $end++
    }

    $text = $Encoding.GetString($Bytes, $start, $end - $start)
    $Offset.Value = [Math]::Min($Bytes.Length, $end + 1)
    return $text
}

function Decode-Id3TextFrame {
    param([byte[]]$Payload)

    if ($Payload.Length -eq 0) {
        return ''
    }

    switch ($Payload[0]) {
        0 { return [Text.Encoding]::GetEncoding(28591).GetString($Payload, 1, $Payload.Length - 1).TrimEnd([char]0) }
        1 { return [Text.Encoding]::Unicode.GetString($Payload, 1, $Payload.Length - 1).TrimEnd([char]0) }
        2 { return [Text.Encoding]::BigEndianUnicode.GetString($Payload, 1, $Payload.Length - 1).TrimEnd([char]0) }
        3 { return [Text.Encoding]::UTF8.GetString($Payload, 1, $Payload.Length - 1).TrimEnd([char]0) }
        default { return [Text.Encoding]::GetEncoding(28591).GetString($Payload, 1, $Payload.Length - 1).TrimEnd([char]0) }
    }
}

function Convert-ToFlacPictureBase64 {
    param(
        [byte[]]$ImageData,
        [string]$Mime,
        [string]$Description = '',
        [int]$PictureType = 3
    )

    Add-Type -AssemblyName System.Drawing | Out-Null

    $width = 0
    $height = 0
    $depth = 0
    $colors = 0

    $imageStream = New-Object System.IO.MemoryStream(, $ImageData)
    try {
        $image = [System.Drawing.Image]::FromStream($imageStream)
        try {
            $width = $image.Width
            $height = $image.Height
            $depth = [System.Drawing.Image]::GetPixelFormatSize($image.PixelFormat)
        } finally {
            $image.Dispose()
        }
    } finally {
        $imageStream.Dispose()
    }

    $mimeBytes = [Text.Encoding]::ASCII.GetBytes($Mime)
    $descBytes = [Text.Encoding]::UTF8.GetBytes($Description)

    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)
    try {
        Write-UInt32BE -Writer $bw -Value ([uint32]$PictureType)
        Write-UInt32BE -Writer $bw -Value ([uint32]$mimeBytes.Length)
        $bw.Write($mimeBytes)
        Write-UInt32BE -Writer $bw -Value ([uint32]$descBytes.Length)
        $bw.Write($descBytes)
        Write-UInt32BE -Writer $bw -Value ([uint32]$width)
        Write-UInt32BE -Writer $bw -Value ([uint32]$height)
        Write-UInt32BE -Writer $bw -Value ([uint32]$depth)
        Write-UInt32BE -Writer $bw -Value ([uint32]$colors)
        Write-UInt32BE -Writer $bw -Value ([uint32]$ImageData.Length)
        $bw.Write($ImageData)
        return [Convert]::ToBase64String($ms.ToArray())
    } finally {
        $bw.Dispose()
        $ms.Dispose()
    }
}

function Get-WavId3Info {
    param([string]$Path)

    $bytes = [IO.File]::ReadAllBytes($Path)
    $id3Offset = -1

    for ($i = $bytes.Length - 10; $i -ge 0; $i--) {
        if ($bytes[$i] -eq 0x49 -and $bytes[$i + 1] -eq 0x44 -and $bytes[$i + 2] -eq 0x33) {
            $id3Offset = $i
            break
        }
    }

    if ($id3Offset -lt 0) {
        return $null
    }

    $tagSize = Read-SynchsafeInt -Bytes $bytes -Offset ($id3Offset + 6)
    $offset = $id3Offset + 10
    $limit = [Math]::Min($bytes.Length, $offset + $tagSize)

    $metadata = [ordered]@{}
    $picture = $null

    while ($offset + 10 -le $limit) {
        $frameId = [Text.Encoding]::ASCII.GetString($bytes, $offset, 4)
        if ($frameId.Trim([char]0).Length -eq 0) {
            break
        }

        $frameSize = Read-UInt32BE -Bytes $bytes -Offset ($offset + 4)
        if ($frameSize -le 0 -or $offset + 10 + $frameSize -gt $limit) {
            break
        }

        $payload = New-Object byte[] $frameSize
        [Array]::Copy($bytes, $offset + 10, $payload, 0, $frameSize)

        switch ($frameId) {
            'TIT2' { $metadata.title = Decode-Id3TextFrame $payload }
            'TALB' { $metadata.album = Decode-Id3TextFrame $payload }
            'TPE1' { $metadata.artist = Decode-Id3TextFrame $payload }
            'TPE2' { $metadata.album_artist = Decode-Id3TextFrame $payload }
            'TCON' { $metadata.genre = Decode-Id3TextFrame $payload }
            'TRCK' { $metadata.track = Decode-Id3TextFrame $payload }
            'TYER' { $metadata.date = Decode-Id3TextFrame $payload }
            'TDRC' { $metadata.date = Decode-Id3TextFrame $payload }
            'COMM' {
                if (-not $metadata.comment) {
                    $metadata.comment = Decode-Id3TextFrame $payload
                }
            }
            'APIC' {
                $payloadOffset = 1
                $mime = Read-NulTerminatedString -Bytes $payload -Offset ([ref]$payloadOffset) -Encoding ([Text.Encoding]::ASCII)
                if ($payloadOffset -ge $payload.Length) {
                    break
                }

                $pictureType = $payload[$payloadOffset]
                $payloadOffset++
                $descriptionEncoding = switch ($payload[0]) {
                    0 { [Text.Encoding]::GetEncoding(28591) }
                    1 { [Text.Encoding]::Unicode }
                    2 { [Text.Encoding]::BigEndianUnicode }
                    3 { [Text.Encoding]::UTF8 }
                    default { [Text.Encoding]::GetEncoding(28591) }
                }
                $description = Read-NulTerminatedString -Bytes $payload -Offset ([ref]$payloadOffset) -Encoding $descriptionEncoding
                $image = New-Object byte[] ($payload.Length - $payloadOffset)
                [Array]::Copy($payload, $payloadOffset, $image, 0, $image.Length)

                $picture = [pscustomobject]@{
                    Mime = $mime
                    Type = $pictureType
                    Description = $description
                    Image = $image
                }
            }
        }

        $offset += 10 + $frameSize
    }

    if (-not $picture) {
        return [pscustomobject]@{
            Metadata = $metadata
            PictureBase64 = $null
        }
    }

    $metadata['METADATA_BLOCK_PICTURE'] = Convert-ToFlacPictureBase64 -ImageData $picture.Image -Mime $picture.Mime -Description $picture.Description -PictureType $picture.Type

    return [pscustomobject]@{
        Metadata = $metadata
        PictureBase64 = $metadata['METADATA_BLOCK_PICTURE']
    }
}

function Write-FfMetadataFile {
    param(
        [string]$Path,
        [hashtable]$Metadata
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add(';FFMETADATA1')

    foreach ($key in @('title', 'album', 'artist', 'album_artist', 'genre', 'date', 'track', 'comment', 'METADATA_BLOCK_PICTURE')) {
        if ($Metadata.ContainsKey($key) -and $Metadata[$key]) {
            $lines.Add(('{0}={1}' -f $key, (Escape-FfMetadataValue -Value ([string]$Metadata[$key]))))
        }
    }

    Set-Content -LiteralPath $Path -Value $lines -Encoding Ascii
}

function Invoke-Ffmpeg {
    param(
        [string[]]$Arguments
    )

    & $ffmpeg @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "ffmpeg failed with exit code $LASTEXITCODE"
    }
}

Test-File $ffmpeg
Test-File $input

New-Item -ItemType Directory -Force -Path $outdir | Out-Null

$env:PATH = "$ffmpegDir;C:\msys64\mingw64\bin;$env:PATH"

$coverInfo = Get-WavId3Info -Path $input
if (-not $coverInfo) {
    throw "No ID3 metadata was found in $input"
}

$mp3 = Join-Path $outdir 'test.mp3'
$opus = Join-Path $outdir 'test.opus'
$flac = Join-Path $outdir 'test.flac'

$m4a_configs = @(
    @{ name = 'cbr_128k'; type = 'cbr'; value = '128k' },
    @{ name = 'cbr_192k'; type = 'cbr'; value = '192k' },
    @{ name = 'vbr_0.6';  type = 'vbr'; value = '0.6' },
    @{ name = 'vbr_1.0';  type = 'vbr'; value = '1' },
    @{ name = 'vbr_2.0';  type = 'vbr'; value = '2' }
)

$m4a_files = $m4a_configs | ForEach-Object { Join-Path $outdir "test_$($_.name).m4a" }

Remove-Item -LiteralPath ($mp3, $opus, $flac, $metaFile + $m4a_files) -Force -ErrorAction SilentlyContinue

if ($coverInfo.PictureBase64) {
    Write-FfMetadataFile -Path $metaFile -Metadata $coverInfo.Metadata
}

Write-Host '[1/4] MP3'
Invoke-Ffmpeg @(
    '-hide_banner', '-y',
    '-i', $input,
    '-map', '0:a:0',
    '-map', '0:v?',
    '-map_metadata', '0',
    '-map_chapters', '0',
    '-c:a', 'libmp3lame',
    '-c:v', 'mjpeg',
    '-disposition:v:0', 'attached_pic',
    '-metadata:s:v:0', 'title=Cover',
    '-metadata:s:v:0', 'comment=Cover (front)',
    '-id3v2_version', '3',
    $mp3
)

Write-Host '[2/4] Opus'
$opusArgs = @(
    '-hide_banner', '-y',
    '-i', $input
)
if ($coverInfo.PictureBase64) {
    $opusArgs += @(
        '-f', 'ffmetadata',
        '-i', $metaFile
    )
}
$opusArgs += @(
    '-map', '0:a:0',
    '-map_chapters', '0'
)
if ($coverInfo.PictureBase64) {
    $opusArgs += @(
        '-map_metadata', '1'
    )
} else {
    $opusArgs += @(
        '-map_metadata', '0'
    )
}
$opusArgs += @(
    '-c:a', 'libopus',
    $opus
)
Invoke-Ffmpeg $opusArgs

Write-Host '[3/8] FLAC'
Invoke-Ffmpeg @(
    '-hide_banner', '-y',
    '-i', $input,
    '-map', '0:a:0',
    '-map', '0:v?',
    '-map_metadata', '0',
    '-map_chapters', '0',
    '-c:a', 'flac',
    '-c:v', 'mjpeg',
    '-disposition:v:0', 'attached_pic',
    '-metadata:s:v:0', 'title=Cover',
    '-metadata:s:v:0', 'comment=Cover (front)',
    $flac
)

for ($i = 0; $i -lt $m4a_configs.Length; $i++) {
    $config = $m4a_configs[$i]
    $m4a_file = $m4a_files[$i]
    $step = 4 + $i
    Write-Host "[$step/8] M4A ($($config.name))"
    
    $args = @(
        '-hide_banner', '-y',
        '-i', $input,
        '-map', '0:a:0',
        '-map', '0:v?',
        '-map_metadata', '0',
        '-map_chapters', '0',
        '-c:a', 'aac'
    )
    
    if ($config.type -eq 'cbr') {
        $args += '-b:a', $config.value
    } else {
        $args += '-q:a', $config.value
    }
    
    $args += @(
        '-c:v', 'mjpeg',
        '-disposition:v:0', 'attached_pic',
        '-metadata:s:v:0', 'title=Cover',
        '-metadata:s:v:0', 'comment=Cover (front)',
        '-movflags', '+faststart',
        $m4a_file
    )
    
    Invoke-Ffmpeg $args
}

if ($coverInfo.PictureBase64) {
    Write-Host 'Prepared Opus metadata with embedded cover art.'
}

Write-Host "Outputs are in $outdir"
