#!/bin/bash
set -e

# Usage: ./combine_videos.sh
# Run this from inside the folder containing your video clips.
# Combines all .mp4/.mov/.MOV/.MP4 files into one output.mp4, in filename order.

OUTPUT="combined_output.mp4"
TMPDIR="_normalized_clips"
LISTFILE="_concat_list.txt"

mkdir -p "$TMPDIR"
rm -f "$LISTFILE"

# Collect all video files, sorted by name (change to `ls -tr` for oldest-first by time)
shopt -s nullglob nocaseglob
files=(*.mp4 *.mov)
shopt -u nocaseglob

if [ ${#files[@]} -eq 0 ]; then
  echo "No video files found in this folder."
  exit 1
fi

echo "Found ${#files[@]} video(s). Normalizing..."

i=0
for f in "${files[@]}"; do
  i=$((i+1))
  out="$TMPDIR/clip_$(printf "%03d" "$i").mp4"
  echo "  [$i/${#files[@]}] $f -> $out"
  ffmpeg -y -i "$f" \
    -c:v libx264 -preset fast -crf 20 \
    -vf "scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2,setsar=1" \
    -r 30 \
    -c:a aac -b:a 192k -ar 48000 -ac 2 \
    "$out" -loglevel error
  echo "file '$out'" >> "$LISTFILE"
done

echo "Concatenating..."
ffmpeg -y -f concat -safe 0 -i "$LISTFILE" -c copy "$OUTPUT" -loglevel error

echo "Done! Output: $OUTPUT"
echo "Cleaning up normalized clips..."
rm -rf "$TMPDIR" "$LISTFILE"
