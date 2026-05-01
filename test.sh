#!/usr/bin/env bash
set -euo pipefail

# Use the same root as the script location if not provided
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ffmpeg_dir="$repo_root/build/ffmpeg-audio/install/bin"
ffmpeg="$ffmpeg_dir/ffmpeg"
ffprobe="$ffmpeg_dir/ffprobe"
input="$repo_root/test.wav"
outdir="$repo_root/build/test-output"
meta_file="$outdir/test.opus.ffmetadata"

log() {
    echo "$@"
}

error() {
    echo "Error: $1" >&2
    exit 1
}

test_file() {
    if [[ ! -f "$1" ]]; then
        error "Missing file: $1"
    fi
}

# Ensure tools and input exist
test_file "$ffmpeg"
test_file "$ffprobe"
test_file "$input"

# Create output directory
mkdir -p "$outdir"

# Clean up previous outputs
rm -f "$outdir/test.mp3" "$outdir/test.opus" "$outdir/test.flac" "$outdir/test.m4a" "$meta_file"

log "Extracting metadata and cover art..."

# Extract cover art to temp file if it exists
cover_tmp="$outdir/cover.jpg"
rm -f "$cover_tmp"
if "$ffmpeg" -hide_banner -y -i "$input" -map 0:v:0 -c copy "$cover_tmp" >/dev/null 2>&1; then
    has_cover=true
else
    has_cover=false
fi

# Function to generate FLAC picture block and metadata for Opus
generate_opus_metadata() {
    local input_file="$1"
    local cover_file="$2"
    local output_meta="$3"

    python3 - <<'EOF' "$input_file" "$cover_file" "$output_meta" "$ffprobe"
import sys, os, struct, base64, subprocess, json

input_file = sys.argv[1]
cover_file = sys.argv[2]
output_meta = sys.argv[3]
ffprobe_bin = sys.argv[4]
has_cover = os.path.exists(cover_file)

def get_image_info(path):
    cmd = [ffprobe_bin, "-v", "quiet", "-select_streams", "v:0", "-show_entries", "stream=width,height,pix_fmt", "-print_format", "json", path]
    try:
        res = subprocess.check_output(cmd)
        data = json.loads(res)
        if "streams" in data and len(data["streams"]) > 0:
            s = data["streams"][0]
            return s.get("width", 0), s.get("height", 0), 24
    except:
        pass
    return 0, 0, 24

def get_audio_tags(path):
    cmd = [ffprobe_bin, "-v", "quiet", "-show_format", "-print_format", "json", path]
    try:
        res = subprocess.check_output(cmd)
        data = json.loads(res)
        return data.get("format", {}).get("tags", {})
    except:
        return {}

def escape_val(val):
    return val.replace('\\', '\\\\').replace('\r', '').replace('\n', '\\n').replace(';', '\\;').replace('#', '\\#')

tags = get_audio_tags(input_file)
keys_to_keep = ['title', 'album', 'artist', 'album_artist', 'genre', 'date', 'track', 'comment']

lines = [";FFMETADATA1"]
for k in keys_to_keep:
    v = tags.get(k) or tags.get(k.upper())
    if v:
        lines.append(f"{k}={escape_val(str(v))}")

if has_cover:
    width, height, depth = get_image_info(cover_file)
    with open(cover_file, 'rb') as f:
        img_data = f.read()
    
    mime = "image/jpeg"
    description = "Cover (front)"
    
    mime_b = mime.encode('ascii')
    desc_b = description.encode('utf-8')
    
    block = struct.pack('>I', 3)
    block += struct.pack('>I', len(mime_b)) + mime_b
    block += struct.pack('>I', len(desc_b)) + desc_b
    block += struct.pack('>I', width)
    block += struct.pack('>I', height)
    block += struct.pack('>I', depth)
    block += struct.pack('>I', 0)
    block += struct.pack('>I', len(img_data)) + img_data
    
    b64_block = base64.b64encode(block).decode('ascii')
    lines.append(f"METADATA_BLOCK_PICTURE={b64_block}")

with open(output_meta, 'w', encoding='utf-8') as f:
    f.write('\n'.join(lines) + '\n')
EOF
}

if [ "$has_cover" = true ] || "$ffprobe" -show_format "$input" 2>/dev/null | grep -q "TAG:"; then
    generate_opus_metadata "$input" "$cover_tmp" "$meta_file"
    log "Prepared Opus metadata."
fi

log "[1/4] MP3"
"$ffmpeg" -hide_banner -y \
    -i "$input" \
    -map 0:a:0 \
    -map 0:v? \
    -map_metadata 0 \
    -map_chapters 0 \
    -c:a libmp3lame \
    -c:v mjpeg \
    -disposition:v:0 attached_pic \
    -metadata:s:v:0 "title=Cover" \
    -metadata:s:v:0 "comment=Cover (front)" \
    -id3v2_version 3 \
    "$outdir/test.mp3"

log "[2/4] Opus"
opus_args=("-hide_banner" "-y" "-i" "$input")
if [[ -f "$meta_file" ]]; then
    opus_args+=("-f" "ffmetadata" "-i" "$meta_file")
fi
opus_args+=("-map" "0:a:0" "-map_chapters" "0")
if [[ -f "$meta_file" ]]; then
    opus_args+=("-map_metadata" "1")
else
    opus_args+=("-map_metadata" "0")
fi
opus_args+=("-c:a" "libopus" "$outdir/test.opus")
"$ffmpeg" "${opus_args[@]}"

log "[3/4] FLAC"
"$ffmpeg" -hide_banner -y \
    -i "$input" \
    -map 0:a:0 \
    -map 0:v? \
    -map_metadata 0 \
    -map_chapters 0 \
    -c:a flac \
    -c:v mjpeg \
    -disposition:v:0 attached_pic \
    -metadata:s:v:0 "title=Cover" \
    -metadata:s:v:0 "comment=Cover (front)" \
    "$outdir/test.flac"

log "[4/4] M4A"
"$ffmpeg" -hide_banner -y \
    -i "$input" \
    -map 0:a:0 \
    -map 0:v? \
    -map_metadata 0 \
    -map_chapters 0 \
    -c:a aac \
    -c:v mjpeg \
    -disposition:v:0 attached_pic \
    -metadata:s:v:0 "title=Cover" \
    -metadata:s:v:0 "comment=Cover (front)" \
    -movflags +faststart \
    "$outdir/test.m4a"

log "Outputs are in $outdir"
rm -f "$cover_tmp"
