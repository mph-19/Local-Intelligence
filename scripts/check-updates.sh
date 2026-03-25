#!/usr/bin/env bash
# Check all pinned dependencies for available updates.
# Run periodically: ./scripts/check-updates.sh
#
# This only reports — it doesn't change anything.

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo "=== Local Intelligence — Dependency Update Check ==="
echo ""

# ── Git repositories ─────────────────────────────────────────────
echo "── Git Repositories ──"

check_git_pin() {
    local name="$1" url="$2" pinned="$3"
    local latest
    latest=$(git ls-remote "$url" HEAD 2>/dev/null | cut -c1-12)
    if [ "$latest" = "$pinned" ]; then
        printf "  ${GREEN}[current]${NC}  %-12s %s\n" "$name" "$pinned"
    else
        printf "  ${YELLOW}[update]${NC}  %-12s pinned=%s latest=%s\n" "$name" "$pinned" "$latest"
    fi
}

# Extract pinned commits from Dockerfiles
BITNET_PIN=$(grep 'BITNET_COMMIT=' docker/Dockerfile.falcon3 | head -1 | sed 's/.*=//' | tr -d '"')
LLAMA_PIN=$(grep 'LLAMACPP_COMMIT=' docker/Dockerfile.qwen | head -1 | sed 's/.*=//' | tr -d '"')

check_git_pin "BitNet" "https://github.com/microsoft/BitNet.git" "$BITNET_PIN"
check_git_pin "llama.cpp" "https://github.com/ggerganov/llama.cpp.git" "$LLAMA_PIN"

echo ""

# ── Container images ─────────────────────────────────────────────
echo "── Container Images ──"

check_image_tag() {
    local name="$1" repo="$2" current="$3"
    local latest
    # Use docker to check for newer tags (requires docker login for ghcr)
    latest=$(git ls-remote --tags "$repo" 2>/dev/null \
        | grep -v '\^{}' | awk '{print $2}' | sed 's|refs/tags/||' \
        | grep -E '^v?[0-9]+\.[0-9]+' | sort -V | tail -1)
    if [ -z "$latest" ]; then
        printf "  ${RED}[error]${NC}   %-12s could not fetch tags\n" "$name"
    elif [ "$latest" = "$current" ]; then
        printf "  ${GREEN}[current]${NC}  %-12s %s\n" "$name" "$current"
    else
        printf "  ${YELLOW}[update]${NC}  %-12s pinned=%s latest=%s\n" "$name" "$current" "$latest"
    fi
}

KIWIX_PIN=$(grep 'kiwix-serve:' docker-compose.yml | sed 's/.*kiwix-serve://' | tr -d ' "'"'")
WEBUI_PIN=$(grep 'open-webui:' docker-compose.yml | sed 's/.*open-webui://' | tr -d ' "'"'")

check_image_tag "Kiwix" "https://github.com/kiwix/kiwix-tools.git" "$KIWIX_PIN"
check_image_tag "Open WebUI" "https://github.com/open-webui/open-webui.git" "$WEBUI_PIN"

echo ""

# ── Python packages ──────────────────────────────────────────────
echo "── Python Packages ──"
echo "  (Dependabot handles these automatically via PR)"
echo "  To check manually: pip index versions <package>"

echo ""

# ── CUDA base images ────────────────────────────────────────────
echo "── CUDA Base Images ──"
CUDA_VER=$(grep 'nvidia/cuda:' docker/Dockerfile.qwen | head -1 | sed 's/.*nvidia\/cuda://' | cut -d- -f1)
printf "  [pinned]  CUDA %s — check https://hub.docker.com/r/nvidia/cuda/tags for newer\n" "$CUDA_VER"

echo ""

# ── HuggingFace models ──────────────────────────────────────────
echo "── HuggingFace Models ──"
echo "  These are pinned by name, not version. Check for updates at:"
echo "    - https://huggingface.co/tiiuae/Falcon3-10B-Instruct-1.58bit"
echo "    - https://huggingface.co/unsloth/Qwen3.5-9B-GGUF"
echo "    - https://huggingface.co/nomic-ai/nomic-embed-text-v1.5"

echo ""
echo "=== Done ==="
