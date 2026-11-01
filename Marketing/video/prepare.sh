#!/bin/zsh
# Builds the media under public/ that stays out of git: footage clips, draft voice, grain, music.
#   zsh prepare.sh <dir holding the 2026-10-28 DIAG runs>
set -e
cd "${0:A:h}"
diag="${1:?usage: prepare.sh <diag dir>}"
mkdir -p public/footage public/vo public/img

clip() {  # source run id, start s, length s, name, extra filter
  local src=$(find "$diag" -path "*$1*" -name camera.mp4 | head -1)
  ffmpeg -v error -y -ss $2 -t $3 -i "$src" -vf "transpose=1${5:+,$5},scale=720:960,fps=30" \
    -an -c:v libx264 -crf 18 -pix_fmt yuv420p public/footage/$4.mp4
}
night="eq=brightness=0.05:gamma=1.5:saturation=0.85"
clip 7EC55FB7 33 8 street1 $night
clip 7EC55FB7 41 8 street2 $night
clip 7EC55FB7 58 7 station $night
clip EF9E139B 6 8 indoor
ffmpeg -v error -y -ss 2 -i public/footage/indoor.mp4 -frames:v 1 -q:v 2 public/img/hall.jpg
ffmpeg -v error -y -ss 3 -i public/footage/street1.mp4 -frames:v 1 -q:v 2 public/img/street.jpg

# Film grain tile, shifted every frame by the film.
ffmpeg -v error -y -f lavfi -i "nullsrc=s=512x512,geq=lum='random(1)*255':cb=128:cr=128" -frames:v 1 public/img/grain.png

while IFS='|' read id text; do
  say -v Tingting -r 165 -o "$TMPDIR/$id.aiff" "$text"
  ffmpeg -v error -y -i "$TMPDIR/$id.aiff" -ar 48000 public/vo/$id.wav
  printf "%s %.1f\n" $id $(ffprobe -v error -show_entries format=duration -of csv=p=0 public/vo/$id.wav)
done < vo.txt

[[ -f public/music.mp3 ]] || curl -s -A "curl/8" -o public/music.mp3 \
  "https://incompetech.com/music/royalty-free/mp3-royaltyfree/Clean%20Soul.mp3"

cp ../../PRTS/Assets.xcassets/AppIcon.appiconset/AppIcon.png public/img/icon.png

# Edge points of one street frame: the scene the cane and the phone "see" in the film.
ffmpeg -v error -y -i public/img/street.jpg -vf "scale=180:240,format=gray,edgedetect=low=0.08:high=0.2" -f rawvideo - |
  python3 -c '
import sys, json, random
w, h = 180, 240
px = sys.stdin.buffer.read()
pts = [(x, y) for y in range(h) for x in range(w) if px[y * w + x] > 100]
random.seed(7); random.shuffle(pts)
json.dump([[round(x / w, 3), round(y / h, 3)] for x, y in pts[:2200]], open("public/street-points.json", "w"))
print(len(pts), "edge pixels")'
