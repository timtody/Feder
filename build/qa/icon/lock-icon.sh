#!/bin/zsh
# lock-icon.sh: renders Feder's app icon (Recorder/AppIcon.icon, read only) into Recorder/Assets.xcassets/AppLockIcon,
# the picture on App Lock's cover (AppLockView), light and dark at 100 pt, 2x and 3x, with Icon Composer's own renderer,
# so it is the icon as the Home Screen draws it (squircle, glass, lighting). No API loads an app's icon as an image.
# Rerun it whenever the app icon changes, and commit the PNGs.
cd /Users/julius.taylor/projects/recorder || exit 1
IC="/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
out=Recorder/Assets.xcassets/AppLockIcon.imageset
for rendition in Default Dark; do
  suffix=${${rendition:#Default}:+-$rendition}
  for scale in 2 3; do
    "$IC" Recorder/AppIcon.icon --export-image --output-file $out/AppLockIcon$suffix@${scale}x.png --platform iOS \
      --rendition $rendition --width 100 --height 100 --scale $scale >/dev/null || exit 1
  done
done
ls -l $out/*.png
