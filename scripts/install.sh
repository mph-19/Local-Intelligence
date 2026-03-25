#!/usr/bin/env bash
# Local Intelligence — single-command installer
# Installs all dependencies, builds bitnet.cpp, downloads the model,
# sets up the knowledge directory, and configures systemd services.
#
# Supports: Linux (x86_64, ARM64), macOS (Intel, Apple Silicon)
# Requires: bash, curl, git (will install the rest)
#
# Usage:
#   bash install.sh              # interactive (asks before each step)
#   bash install.sh --yes        # non-interactive (accept all defaults)
#   bash install.sh --no-model   # skip the ~2GB model download
#   bash install.sh --help       # show usage

set -euo pipefail

# ── Defaults ─────────────────────────────────────────────────────────
KNOWLEDGE_DIR="${KNOWLEDGE_DIR:-/knowledge}"
MODEL_REPO="tiiuae/Falcon3-10B-Instruct-1.58bit"
MODEL_QUANT="i2_s"
LLM_PORT=8080
ORCHESTRATOR_PORT=8081
KIWIX_PORT=8888
WEBUI_PORT=3000
AUTO_YES=false
SKIP_MODEL=false

# ── Parse args ───────────────────────────────────────────────────────
for arg in "$@"; do
    case "$arg" in
        --yes|-y)       AUTO_YES=true ;;
        --no-model)     SKIP_MODEL=true ;;
        --help|-h)
            echo "Usage: bash install.sh [--yes] [--no-model] [--help]"
            echo ""
            echo "  --yes        Non-interactive, accept all defaults"
            echo "  --no-model   Skip downloading the ~2GB Falcon3 model"
            echo "  --help       Show this message"
            echo ""
            echo "Environment variables:"
            echo "  KNOWLEDGE_DIR  Where to store data (default: /knowledge)"
            exit 0
            ;;
    esac
done

# ── Helpers ──────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
fail()  { echo -e "${RED}[FAIL]${NC}  $*"; exit 1; }

confirm() {
    if $AUTO_YES; then return 0; fi
    read -rp "$1 [Y/n] " ans
    case "${ans,,}" in
        ""|y|yes) return 0 ;;
        *) return 1 ;;
    esac
}

# ── Detect platform ─────────────────────────────────────────────────
detect_platform() {
    OS="$(uname -s)"
    ARCH="$(uname -m)"

    case "$OS" in
        Linux)  PLATFORM="linux" ;;
        Darwin) PLATFORM="macos" ;;
        MINGW*|MSYS*|CYGWIN*)
            fail "Windows detected. Use Docker instead: docker compose up -d"
            ;;
        *)
            fail "Unsupported OS: $OS"
            ;;
    esac

    case "$ARCH" in
        x86_64|amd64)   ARCH="x86_64" ;;
        aarch64|arm64)  ARCH="arm64" ;;
        *)
            fail "Unsupported architecture: $ARCH"
            ;;
    esac

    # Detect package manager (Linux only)
    PKG_MGR=""
    if [ "$PLATFORM" = "linux" ]; then
        if command -v pacman &>/dev/null; then
            PKG_MGR="pacman"
        elif command -v apt-get &>/dev/null; then
            PKG_MGR="apt"
        elif command -v dnf &>/dev/null; then
            PKG_MGR="dnf"
        else
            fail "No supported package manager found (pacman, apt, dnf)."
        fi
    fi

    # Detect init system
    HAS_SYSTEMD=false
    if command -v systemctl &>/dev/null && [ -d /run/systemd/system ]; then
        HAS_SYSTEMD=true
    fi

    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║     Local Intelligence Installer     ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════╝${NC}"
    echo ""
    info "Platform:     $PLATFORM ($ARCH)"
    [ -n "$PKG_MGR" ] && info "Package mgr:  $PKG_MGR"
    info "Systemd:      $HAS_SYSTEMD"
    info "Knowledge dir: $KNOWLEDGE_DIR"
    echo ""
}

# ── Step 1: System dependencies ──────────────────────────────────────
install_system_deps() {
    info "Step 1/7: System dependencies"

    if [ "$PLATFORM" = "macos" ]; then
        if ! command -v brew &>/dev/null; then
            fail "Homebrew not found. Install from https://brew.sh"
        fi
        # cmake and clang via Xcode/Homebrew
        brew install cmake python3 kiwix-tools 2>/dev/null || true

        # Check clang version
        CLANG_VER=$(clang --version 2>/dev/null | head -1 | sed 's/[^0-9].*//' | grep -o '[0-9]*' | head -1)
        CLANG_VER="${CLANG_VER:-0}"
        if [ "$CLANG_VER" -lt 18 ]; then
            info "Installing clang 18+ via Homebrew..."
            brew install llvm
            export PATH="$(brew --prefix llvm)/bin:$PATH"
        fi
        ok "macOS dependencies ready"
        return
    fi

    # Linux
    case "$PKG_MGR" in
        pacman)
            sudo pacman -S --needed --noconfirm \
                clang cmake python python-pip git kiwix-tools docker 2>/dev/null || true
            ;;
        apt)
            sudo apt-get update -qq
            sudo apt-get install -y -qq \
                cmake python3 python3-pip python3-venv git kiwix-tools \
                docker.io curl wget build-essential 2>/dev/null || true

            # Clang 18+ — Ubuntu/Debian repos often have older versions
            CLANG_VER=$(clang --version 2>/dev/null | head -1 | sed 's/[^0-9].*//' | grep -o '[0-9]*' | head -1)
            CLANG_VER="${CLANG_VER:-0}"
            if [ "$CLANG_VER" -lt 18 ]; then
                info "Installing clang 18 via LLVM APT repo..."
                wget -qO- https://apt.llvm.org/llvm.sh | sudo bash -s -- 18
                sudo update-alternatives --install /usr/bin/clang clang /usr/bin/clang-18 100
                sudo update-alternatives --install /usr/bin/clang++ clang++ /usr/bin/clang++-18 100
            fi
            ;;
        dnf)
            sudo dnf install -y \
                clang cmake python3 python3-pip git kiwix-tools docker 2>/dev/null || true
            ;;
    esac

    # Verify clang version
    if command -v clang &>/dev/null; then
        CLANG_VER=$(clang --version 2>/dev/null | head -1 | sed 's/[^0-9].*//' | grep -o '[0-9]*' | head -1)
        CLANG_VER="${CLANG_VER:-0}"
        if [ "$CLANG_VER" -lt 18 ]; then
            fail "clang 18+ required, found clang $CLANG_VER. Install manually."
        fi
        ok "clang $CLANG_VER found"
    else
        fail "clang not found. Install clang 18+ and retry."
    fi

    ok "System dependencies ready"
}

# ── Step 2: Knowledge directory ──────────────────────────────────────
setup_knowledge_dir() {
    info "Step 2/7: Knowledge directory"

    if [ -d "$KNOWLEDGE_DIR" ]; then
        ok "$KNOWLEDGE_DIR already exists"
    else
        if confirm "Create $KNOWLEDGE_DIR?"; then
            sudo mkdir -p "$KNOWLEDGE_DIR"
            sudo chown "$(whoami):$(id -gn)" "$KNOWLEDGE_DIR"
            ok "Created $KNOWLEDGE_DIR"
        else
            warn "Skipped. Set KNOWLEDGE_DIR to a writable path and re-run."
            return
        fi
    fi

    # Create structure
    mkdir -p "$KNOWLEDGE_DIR"/{zim,vectors/qdrant,models,lora,docs/custom,services,logs}
    ok "Directory structure ready"
}

# ── Step 3: Python dependencies ──────────────────────────────────────
install_python_deps() {
    info "Step 3/7: Python dependencies"

    # Use a venv if not already in one
    VENV_DIR="$KNOWLEDGE_DIR/venv"
    if [ -z "${VIRTUAL_ENV:-}" ]; then
        if [ ! -d "$VENV_DIR" ]; then
            python3 -m venv "$VENV_DIR"
            info "Created venv at $VENV_DIR"
        fi
        # shellcheck disable=SC1091
        source "$VENV_DIR/bin/activate"
        ok "Activated venv"
    fi

    pip install --quiet --upgrade pip
    pip install --quiet --upgrade \
        fastapi uvicorn pydantic \
        qdrant-client \
        sentence-transformers \
        requests beautifulsoup4 tqdm \
        openai huggingface-hub

    ok "Python packages installed"
}

# ── Step 4: Build bitnet.cpp ─────────────────────────────────────────
build_bitnet() {
    info "Step 4/7: bitnet.cpp"

    BITNET_DIR="$KNOWLEDGE_DIR/services/bitnet-cpp"

    if [ -d "$BITNET_DIR" ]; then
        ok "bitnet-cpp already cloned at $BITNET_DIR"
    else
        info "Cloning bitnet.cpp..."
        BITNET_COMMIT="${BITNET_COMMIT:-01eb415772c3}"
        git clone --recursive https://github.com/microsoft/BitNet.git "$BITNET_DIR"
        cd "$BITNET_DIR" && git checkout "$BITNET_COMMIT" && git submodule update --init --recursive && cd -
    fi

    cd "$BITNET_DIR"

    # Activate venv if we created one
    if [ -f "$KNOWLEDGE_DIR/venv/bin/activate" ]; then
        # shellcheck disable=SC1091
        source "$KNOWLEDGE_DIR/venv/bin/activate"
    fi

    pip install --quiet -r requirements.txt

    if $SKIP_MODEL; then
        info "Building without model download (--no-model)"
        # Just build the binary, don't download the model
        cmake -B build -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++
        cmake --build build --config Release -j"$(nproc 2>/dev/null || sysctl -n hw.ncpu)"
        ok "bitnet.cpp built (no model)"
    else
        info "Building bitnet.cpp and downloading Falcon3 10B (~2 GB)..."
        info "This may take a while on first run."
        python setup_env.py --hf-repo "$MODEL_REPO" -q "$MODEL_QUANT"
        ok "bitnet.cpp built + Falcon3 10B downloaded"
    fi

    cd - >/dev/null
}

# ── Step 5: Copy service scripts ─────────────────────────────────────
install_services() {
    info "Step 5/7: Service scripts"

    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
    SERVICES_DIR="$KNOWLEDGE_DIR/services"

    # Copy rag.py if the project has it embedded in docs
    # For now, create a marker so users know where to put it
    if [ ! -f "$SERVICES_DIR/rag.py" ]; then
        info "Service scripts need to be copied from the project docs."
        info "See docs/RAG_PIPELINE.md and docs/ORCHESTRATOR.md for the source."
        warn "Copy rag.py and orchestrator.py to $SERVICES_DIR/"
    else
        ok "rag.py found"
    fi

    ok "Service directory ready at $SERVICES_DIR"
}

# ── Step 6: systemd services (Linux only) ────────────────────────────
install_systemd_services() {
    if ! $HAS_SYSTEMD; then
        info "Step 6/7: Skipping systemd (not available)"
        info "Start services manually — see docs/BITNET_SERVER.md"
        return
    fi

    info "Step 6/7: systemd services"

    if ! confirm "Install systemd service files?"; then
        warn "Skipped systemd setup"
        return
    fi

    BITNET_DIR="$KNOWLEDGE_DIR/services/bitnet-cpp"
    MODEL_PATH="$BITNET_DIR/models/Falcon3-10B-Instruct-1.58bit/ggml-model-i2_s.gguf"
    VENV_PYTHON="$KNOWLEDGE_DIR/venv/bin/python3"
    CURRENT_USER="$(whoami)"
    CPU_THREADS=$(( $(nproc 2>/dev/null || sysctl -n hw.ncpu) - 2 ))
    [ "$CPU_THREADS" -lt 2 ] && CPU_THREADS=2

    # Falcon3 server
    sudo tee /etc/systemd/system/falcon3-server.service >/dev/null <<UNIT
[Unit]
Description=Falcon3 10B LLM Server (CPU)
After=local-fs.target

[Service]
ExecStart=$BITNET_DIR/build/bin/llama-server \\
  --model $MODEL_PATH \\
  --host 0.0.0.0 --port $LLM_PORT \\
  --n-gpu-layers 0 --ctx-size 32768 \\
  --threads $CPU_THREADS
Restart=on-failure
RestartSec=5
User=$CURRENT_USER

[Install]
WantedBy=multi-user.target
UNIT

    # Orchestrator
    sudo tee /etc/systemd/system/orchestrator.service >/dev/null <<UNIT
[Unit]
Description=Local Intelligence Query Orchestrator
After=falcon3-server.service
Wants=falcon3-server.service

[Service]
ExecStart=$VENV_PYTHON $KNOWLEDGE_DIR/services/orchestrator.py
WorkingDirectory=$KNOWLEDGE_DIR/services
Restart=on-failure
RestartSec=5
User=$CURRENT_USER
Environment=LLM_URL=http://localhost:$LLM_PORT/v1/chat/completions
Environment=KIWIX_URL=http://localhost:$KIWIX_PORT
Environment=ORCHESTRATOR_PORT=$ORCHESTRATOR_PORT

[Install]
WantedBy=multi-user.target
UNIT

    # Kiwix
    sudo tee /etc/systemd/system/kiwix-serve.service >/dev/null <<UNIT
[Unit]
Description=Kiwix Knowledge Server
After=local-fs.target

[Service]
ExecStart=/usr/bin/kiwix-serve --library $KNOWLEDGE_DIR/kiwix-library.xml \\
  --port $KIWIX_PORT --nodatealias
Restart=on-failure
RestartSec=5
User=$CURRENT_USER

[Install]
WantedBy=multi-user.target
UNIT

    sudo systemctl daemon-reload
    ok "Service files installed"
    info "Enable with: sudo systemctl enable --now falcon3-server orchestrator kiwix-serve"
}

# ── Step 7: Verification ─────────────────────────────────────────────
verify_install() {
    info "Step 7/7: Verification"
    echo ""

    BITNET_DIR="$KNOWLEDGE_DIR/services/bitnet-cpp"
    PASS=0
    TOTAL=0

    check() {
        TOTAL=$((TOTAL + 1))
        if "$@" &>/dev/null; then
            ok "$1"
            PASS=$((PASS + 1))
        else
            warn "MISSING: $1"
        fi
    }

    check command -v clang
    check command -v cmake
    check command -v python3
    check command -v git

    if [ -f "$BITNET_DIR/build/bin/llama-server" ]; then
        ok "llama-server binary"
        PASS=$((PASS + 1))
    else
        warn "MISSING: llama-server binary"
    fi
    TOTAL=$((TOTAL + 1))

    if ls "$BITNET_DIR"/models/*/ggml-model-*.gguf &>/dev/null 2>&1; then
        ok "Falcon3 GGUF model"
        PASS=$((PASS + 1))
    elif $SKIP_MODEL; then
        warn "Model not downloaded (--no-model flag used)"
    else
        warn "MISSING: Falcon3 GGUF model"
    fi
    TOTAL=$((TOTAL + 1))

    check test -d "$KNOWLEDGE_DIR/vectors/qdrant"
    check test -d "$KNOWLEDGE_DIR/zim"
    check test -d "$KNOWLEDGE_DIR/services"

    if command -v kiwix-serve &>/dev/null; then
        ok "kiwix-serve"
        PASS=$((PASS + 1))
    else
        warn "MISSING: kiwix-serve (install kiwix-tools)"
    fi
    TOTAL=$((TOTAL + 1))

    echo ""
    echo -e "${BOLD}══════════════════════════════════════${NC}"
    echo -e "${BOLD}  Results: $PASS/$TOTAL checks passed${NC}"
    echo -e "${BOLD}══════════════════════════════════════${NC}"
    echo ""

    if ! $SKIP_MODEL && [ -f "$BITNET_DIR/build/bin/llama-server" ]; then
        echo "Quick test — start the server:"
        echo ""
        echo "  $BITNET_DIR/build/bin/llama-server \\"
        echo "    --model $BITNET_DIR/models/Falcon3-10B-Instruct-1.58bit/ggml-model-i2_s.gguf \\"
        echo "    --host 127.0.0.1 --port $LLM_PORT \\"
        echo "    --n-gpu-layers 0 --ctx-size 4096 --threads $(nproc 2>/dev/null || echo 4)"
        echo ""
    fi

    echo "Next steps:"
    echo "  1. Download ZIM files     → see docs/KIWIX_SETUP.md"
    echo "  2. Copy service scripts   → see docs/RAG_PIPELINE.md, docs/ORCHESTRATOR.md"
    echo "  3. Index documents        → python scripts/ingest_docs.py"
    echo "  4. Deploy Open WebUI      → see docs/WEB_ACCESS.md"
    echo ""
    echo "Full documentation: docs/"
}

# ── Main ─────────────────────────────────────────────────────────────
main() {
    detect_platform

    if ! confirm "Install Local Intelligence?"; then
        echo "Cancelled."
        exit 0
    fi

    echo ""
    install_system_deps
    echo ""
    setup_knowledge_dir
    echo ""
    install_python_deps
    echo ""
    build_bitnet
    echo ""
    install_services
    echo ""
    install_systemd_services
    echo ""
    verify_install
}

main
