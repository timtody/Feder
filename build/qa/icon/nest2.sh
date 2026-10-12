#!/bin/zsh
# nest2.sh <out.icon> <insets> [round]: the feather and its nested feathers, composed and rendered
rm -rf $1; python3 feather.py $1 bend=0.14 w=0.2 rach=0.0095 cuts=0.34:0.45:-1:0.09,0.64:0.42:-1:0.08,0.54:0.58:1:0.105 slant=0.3 spp=0.55 spe=0.995 hair=0 spk=0.78 round=${3:-0.03} insets=$2 && python3 compose.py $1
