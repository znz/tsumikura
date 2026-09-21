#!/usr/bin/env bash
# public/icon.svg から PWA 用の PNG を作り直す。
# 開発機に画像ツールを入れずに済むよう、使い捨ての Docker コンテナ (rsvg-convert) で描く。
#   script/generate_icons.sh
# 作るもの:
#   public/icon.png             512px  通常のアイコン (角丸)
#   public/icon-192.png         192px  同上
#   public/icon-maskable.png    512px  Android の切り抜き用。全面塗りで、図柄を安全域 (中央 80% の円) に収める
#   public/apple-touch-icon.png 180px  iOS 用。iOS が自分で角を丸めるので全面塗り
set -euo pipefail

cd "$(dirname "$0")/../public"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cp icon.svg "$work/icon.svg"

# icon.svg の図柄 (path) を取り出し、背景を全面塗りにして中心基準で縮めた版を作る
python3 - "$work" <<'PY'
import re, sys
work = sys.argv[1]
svg = open(f"{work}/icon.svg", encoding="utf-8").read()
path = re.search(r"<path[^>]*/>", svg, re.S).group(0)
fill = re.search(r'<rect[^>]*fill="([^"]+)"', svg).group(1)

def variant(scale):
    return f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" width="512" height="512">
  <rect width="512" height="512" fill="{fill}"/>
  <g transform="translate(256 256) scale({scale}) translate(-256 -256)">{path}</g>
</svg>
'''

open(f"{work}/maskable.svg", "w", encoding="utf-8").write(variant(0.72))
open(f"{work}/apple.svg", "w", encoding="utf-8").write(variant(0.9))
PY

docker run --rm -v "$work:/work" -w /work alpine:3.22 sh -c '
  apk add --no-cache rsvg-convert >/dev/null
  rsvg-convert -w 512 -h 512 icon.svg     -o icon.png
  rsvg-convert -w 192 -h 192 icon.svg     -o icon-192.png
  rsvg-convert -w 512 -h 512 maskable.svg -o icon-maskable.png
  rsvg-convert -w 180 -h 180 apple.svg    -o apple-touch-icon.png
  chown '"$(id -u):$(id -g)"' ./*.png
'

cp "$work"/icon.png "$work"/icon-192.png "$work"/icon-maskable.png "$work"/apple-touch-icon.png .
ls -l icon.png icon-192.png icon-maskable.png apple-touch-icon.png
