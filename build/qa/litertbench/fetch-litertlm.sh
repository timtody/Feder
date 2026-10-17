#!/bin/zsh
# LiteRT-LM v0.18.0 for the bench without cloning its repository (it uses Git LFS, which Xcode's git lacks): the
# release's Mac xcframework (checksum from LiteRT-LM's Package.swift) and the Swift wrapper's sources, into vendor/.
set -e
cd "${0:A:h}"
V=v0.18.0
mkdir -p vendor/LiteRTLM && cd vendor
curl -sfL -o mac.zip "https://github.com/google-ai-edge/LiteRT-LM/releases/download/$V/CLiteRTLM_mac.xcframework.zip"
echo "5f6ee68d95eeccb084c6e66d5ee47255e3020fa0fb29696dd0301ae26d6cfb4f  mac.zip" | shasum -a 256 -c
rm -rf CLiteRTLM_mac.xcframework && unzip -q mac.zip && rm mac.zip
for f in Benchmark Config Conversation EmbeddingEngine EmbeddingEngineConfig Engine ExperimentalFlags LiteRTLMError \
         Message ModelInfo ResponseFormat Tool ToolManager; do
  curl -sfL -o LiteRTLM/$f.swift "https://raw.githubusercontent.com/google-ai-edge/LiteRT-LM/$V/swift/$f.swift"
done
ls
