#!/bin/zsh
# render.sh <icon> <name>: light and dark at 1024 and at home-screen size, side by side in <name>.png
IC="/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
for r in Default Dark; do
  "$IC" $1 --export-image --output-file $2-$r.png --platform iOS --rendition $r --width 1024 --height 1024 --scale 1 >/dev/null 2>&1
  "$IC" $1 --export-image --output-file $2-$r-s.png --platform iOS --rendition $r --width 60 --height 60 --scale 3 >/dev/null 2>&1
done
ffmpeg -v error -y -i $2-Default.png -i $2-Dark.png -i $2-Default-s.png -i $2-Dark-s.png -filter_complex \
  "[0:v]scale=512:512[a];[1:v]scale=512:512[b];[2:v]pad=180:512:0:166:white[c];[3:v]pad=180:512:0:166:black[d];[a][b][c][d]hstack=inputs=4" $2.png
