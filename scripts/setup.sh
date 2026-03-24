#!/usr/bin/env bash
# Local Intelligence — dependency installer
# Detects distro and installs packages accordingly.
# Usage: bash scripts/setup.sh

set -e

KNOWLEDGE_DIR="${KNOWLEDGE_DIR:-/knowledge}"

echo "=== Local Intelligence Setup ==="
echo ""

# --- Detect package manager ---
if command -v pacman &>/dev/null; then
    PKG_MGR="pacman"
    INSTALL="sudo pacman -S --needed --noconfirm"
elif command -v apt-get &>/dev/null; then
    PKG_MGR="apt"
    INSTALL="sudo apt-get install -y"
elif command -v dnf &>/dev/null; then
    PKG_MGR="dnf"
    INSTALL="sudo dnf install -y"
else
    echo "ERROR: No supported package manager found (pacman, apt, dnf)."
    exit 1
fi
echo "Detected package manager: $PKG_MGR"

# --- Check knowledge drive ---
echo ""
echo "[1/6] Checking knowledge drive..."
if mountpoint -q "$KNOWLEDGE_DIR" 2>/dev/null; then
    echo "  $KNOWLEDGE_DIR is mounted."
elif [ -d "$KNOWLEDGE_DIR" ]; then
    echo "  WARNING: $KNOWLEDGE_DIR exists but is not a separate mount."
    echo "  Continuing anyway — consider mounting your 1TB drive here."
else
    echo "  $KNOWLEDGE_DIR does not exist. Creating directory structure..."
    sudo mkdir -p "$KNOWLEDGE_DIR"
    sudo chown "$(whoami):$(id -gn)" "$KNOWLEDGE_DIR"
fi

mkdir -p "$KNOWLEDGE_DIR"/{zim,vectors/qdrant,models,lora,docs/{custom,finetune},services,logs}
echo "  Directory structure ready."

# --- System packages ---
echo ""
echo "[2/6] Installing system packages..."
case $PKG_MGR in
    pacman)
        $INSTALL kiwix-tools cmake python docker tailscale
        ;;
    apt)
        $INSTALL kiwix-tools cmake python3 python3-pip docker.io
        # Tailscale has its own install script for Debian/Ubuntu
        if ! command -v tailscale &>/dev/null; then
            echo "  Installing Tailscale..."
            curl -fsSL https://tailscale.com/install.sh | sh
        fi
        ;;
    dnf)
        $INSTALL kiwix-tools cmake python3 python3-pip docker
        if ! command -v tailscale &>/dev/null; then
            curl -fsSL https://tailscale.com/install.sh | sh
        fi
        ;;
esac

# --- Python dependencies ---
echo ""
echo "[3/6] Installing Python packages..."
VENV_DIR="$KNOWLEDGE_DIR/venv"
if [ -z "${VIRTUAL_ENV:-}" ]; then
    if [ ! -d "$VENV_DIR" ]; then
        python3 -m venv "$VENV_DIR"
        echo "  Created venv at $VENV_DIR"
    fi
    # shellcheck disable=SC1091
    source "$VENV_DIR/bin/activate"
    echo "  Activated venv"
fi

pip install --quiet --upgrade pip
pip install --quiet --upgrade \
    fastapi uvicorn pydantic \
    qdrant-client \
    sentence-transformers \
    requests beautifulsoup4 tqdm \
    openai

echo "  Core packages installed."
echo "  For LoRA fine-tuning, also run:"
echo "    pip install transformers peft bitsandbytes accelerate datasets"

# --- QVAC Fabric (BitNet LoRA) ---
echo ""
echo "[4/6] QVAC Fabric (BitNet LoRA framework)..."
if [ ! -d "$KNOWLEDGE_DIR/qvac-fabric" ]; then
    echo "  Cloning QVAC Fabric..."
    git clone https://github.com/tetherto/qvac-rnd-fabric-llm-bitnet \
        "$KNOWLEDGE_DIR/qvac-fabric"
    pip install --quiet -r "$KNOWLEDGE_DIR/qvac-fabric/requirements.txt"
else
    echo "  Already cloned at $KNOWLEDGE_DIR/qvac-fabric"
fi

# --- Falcon3 model check ---
echo ""
echo "[5/6] Checking for Falcon3 10B model..."
BITNET_DIR="$KNOWLEDGE_DIR/services/bitnet-cpp"
MODEL_DIR="$BITNET_DIR/models/Falcon3-10B-Instruct-1.58bit"
if ls "$MODEL_DIR"/*.gguf &>/dev/null 2>&1; then
    echo "  Model found: $(ls "$MODEL_DIR"/*.gguf)"
elif [ -d "$BITNET_DIR" ]; then
    echo "  bitnet-cpp is cloned but no model found."
    echo "  To download and build, run:"
    echo "    cd $BITNET_DIR && python setup_env.py --hf-repo tiiuae/Falcon3-10B-Instruct-1.58bit -q i2_s"
else
    echo "  bitnet-cpp not yet cloned. To set up:"
    echo "    git clone https://github.com/microsoft/BitNet.git $BITNET_DIR"
    echo "    cd $BITNET_DIR && pip install -r requirements.txt"
    echo "    python setup_env.py --hf-repo tiiuae/Falcon3-10B-Instruct-1.58bit -q i2_s"
fi

# --- Docker / Open WebUI ---
echo ""
echo "[6/6] Docker and Open WebUI..."
if command -v docker &>/dev/null; then
    if docker ps &>/dev/null; then
        echo "  Docker is running."
        if docker ps -a --format '{{.Names}}' | grep -q open-webui; then
            echo "  Open WebUI container exists."
        else
            echo "  Open WebUI not yet deployed. See docs/WEB_ACCESS.md"
        fi
    else
        echo "  Docker installed but not running. Start with: sudo systemctl start docker"
    fi
else
    echo "  Docker not found. Install it for Open WebUI support."
fi

echo ""
echo "=== Setup complete ==="
echo ""
echo "Next steps:"
echo "  1. Mount your 1TB drive at $KNOWLEDGE_DIR (if not already done)"
echo "     See config/drive_layout.md"
echo ""
echo "  2. Download ZIM files:"
echo "     See docs/KIWIX_SETUP.md for URLs and download commands"
echo ""
echo "  3. Build kiwix library:"
echo "     for zim in $KNOWLEDGE_DIR/zim/*.zim; do"
echo "       kiwix-manage $KNOWLEDGE_DIR/kiwix-library.xml add \"\$zim\""
echo "     done"
echo ""
echo "  4. Download Falcon3 and start server:"
echo "     See docs/BITNET_SERVER.md"
echo ""
echo "  5. Start services:"
echo "     sudo systemctl enable --now kiwix-serve falcon3-server orchestrator"
echo ""
echo "  6. Deploy Open WebUI:"
echo "     See docs/WEB_ACCESS.md"
