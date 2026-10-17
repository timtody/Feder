#!/bin/zsh
set -e
cd "${0:A:h}"
R=238767527555cb75a05732a84dff5d6ba0dd6809
for f in config.json generation_config.json chat_template.jinja processor_config.json tokenizer.json tokenizer_config.json model.safetensors.index.json model.safetensors; do
  curl -sfL -C - -o e2b-mlx/$f "https://huggingface.co/mlx-community/gemma-4-e2b-it-4bit/resolve/$R/$f" || curl -sfL -o e2b-mlx/$f "https://huggingface.co/mlx-community/gemma-4-e2b-it-4bit/resolve/$R/$f"
  echo "e2b $f done"
done
curl -sfL -C - -o e4b-litert/gemma-4-E4B-it-gpu.litertlm "https://huggingface.co/litert-community/gemma-4-E4B-it-litert-lm/resolve/2eee7ac325f20eb8c9ac1d0e972f7c84663062da/gemma-4-E4B-it-gpu.litertlm"
echo "e4b gpu done"
