#!/usr/bin/env bash
# Local Intelligence — hardware detection + profile configuration wizard
# Detects system capabilities and writes the matching .env configuration.
#
# Usage:
#   bash scripts/configure.sh            # interactive
#   bash scripts/configure.sh --auto     # auto-select recommended profile
#   bash scripts/configure.sh --profile cpu   # force a specific profile

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_DIR/.env"

# ── Colors ──────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ── Parse args ──────────────────────────────────────────────────────
AUTO=false
FORCE_PROFILE=""

for arg in "$@"; do
    case "$arg" in
        --auto)          AUTO=true ;;
        --profile)       shift; FORCE_PROFILE="${1:-}" ;;
        --profile=*)     FORCE_PROFILE="${arg#*=}" ;;
        --help|-h)
            echo "Usage: bash scripts/configure.sh [--auto] [--profile <name>]"
            echo ""
            echo "  --auto              Auto-select the recommended profile"
            echo "  --profile <name>    Force a profile: cpu, gpu, dual, minimal"
            echo ""
            exit 0
            ;;
    esac
done

# ── Detect hardware ────────────────────────────────────────────────
detect_hardware() {
    # RAM
    if [ -f /proc/meminfo ]; then
        RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
        RAM_GB=$(( RAM_KB / 1048576 ))
    elif command -v sysctl &>/dev/null; then
        RAM_BYTES=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
        RAM_GB=$(( RAM_BYTES / 1073741824 ))
    else
        RAM_GB=0
    fi

    # CPU
    CPU_CORES=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 1)
    CPU_MODEL=$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs || sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "unknown")

    # CPU features
    HAS_AVX2=false
    HAS_AVX512=false
    if grep -q avx2 /proc/cpuinfo 2>/dev/null; then HAS_AVX2=true; fi
    if grep -q avx512 /proc/cpuinfo 2>/dev/null; then HAS_AVX512=true; fi

    # NVIDIA GPU
    # Use -i 0 to query the physical GPU directly — without it, MIG-enabled
    # GPUs may return MIG instance info instead, giving wrong VRAM values.
    # Falls back to plain --query-gpu, then nvidia-smi -L parsing.
    HAS_NVIDIA=false
    NVIDIA_GPU=""
    VRAM_MB=0
    if command -v nvidia-smi &>/dev/null; then
        HAS_NVIDIA=true
        NVIDIA_GPU=$(nvidia-smi -i 0 --query-gpu=name --format=csv,noheader 2>/dev/null \
            || nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 \
            || echo "unknown")
        VRAM_MB=$(nvidia-smi -i 0 --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null \
            || nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 \
            || echo 0)
        # Sanitize: strip whitespace, ensure numeric
        VRAM_MB=$(echo "$VRAM_MB" | tr -dc '0-9')
        [ -z "$VRAM_MB" ] && VRAM_MB=0
    fi

    # Docker + NVIDIA container toolkit
    HAS_DOCKER=false
    HAS_NVIDIA_DOCKER=false
    if command -v docker &>/dev/null && docker ps &>/dev/null 2>&1; then
        HAS_DOCKER=true
        if docker info 2>/dev/null | grep -qi nvidia; then
            HAS_NVIDIA_DOCKER=true
        elif [ -f /etc/docker/daemon.json ] && grep -q nvidia /etc/docker/daemon.json 2>/dev/null; then
            HAS_NVIDIA_DOCKER=true
        fi
    fi
}

# ── Port availability ────────────────────────────────────────────
is_port_free() {
    local port="$1"
    if command -v ss &>/dev/null; then
        ! ss -tlnH "sport = :$port" 2>/dev/null | grep -q .
    elif command -v lsof &>/dev/null; then
        ! lsof -iTCP:"$port" -sTCP:LISTEN &>/dev/null
    elif command -v netstat &>/dev/null; then
        ! netstat -tln 2>/dev/null | grep -q ":$port "
    else
        return 0  # can't check — assume free
    fi
}

find_free_port() {
    local port="$1"
    local tries=0
    while [ $tries -lt 100 ]; do
        if is_port_free "$port"; then
            echo "$port"
            return 0
        fi
        port=$((port + 1))
        tries=$((tries + 1))
    done
    echo "$1"  # exhausted — return original
    return 1
}

check_and_fix_ports() {
    local profile="$1"
    local changed=false
    local new_port

    echo -e "${CYAN}Checking port availability:${NC}"

    # Status goes to stderr; only the (possibly updated) port to stdout.
    _check() {
        local name="$1" port="$2"
        if is_port_free "$port"; then
            echo -e "  ${GREEN}[free]${NC}  ${name}=${port}" >&2
            echo "$port"
        else
            local free
            free=$(find_free_port "$((port + 1))")
            echo -e "  ${YELLOW}[busy]${NC}  ${name}=${port} → reassigned to ${free}" >&2
            echo "$free"
        fi
    }

    # Profile-specific LLM ports
    case "$profile" in
        cpu|dual|minimal)
            new_port=$(_check LLM_PORT "$llm_port")
            [ "$new_port" != "$llm_port" ] && changed=true
            llm_port="$new_port" ;;
    esac
    case "$profile" in
        gpu|dual)
            new_port=$(_check SYNTH_PORT "$synth_port")
            [ "$new_port" != "$synth_port" ] && changed=true
            synth_port="$new_port" ;;
    esac

    # Always-active services
    new_port=$(_check ORCHESTRATOR_PORT "$orch_port")
    [ "$new_port" != "$orch_port" ] && changed=true
    orch_port="$new_port"

    new_port=$(_check KIWIX_PORT "$kiwix_port")
    [ "$new_port" != "$kiwix_port" ] && changed=true
    kiwix_port="$new_port"

    new_port=$(_check WEBUI_PORT "$webui_port")
    [ "$new_port" != "$webui_port" ] && changed=true
    webui_port="$new_port"

    echo ""
    if $changed; then
        echo -e "${YELLOW}Some ports were busy and have been reassigned.${NC}"
        echo -e "${DIM}You can change them later in .env${NC}"
        echo ""
    fi
}

# ── Recommend profile ──────────────────────────────────────────────
recommend_profile() {
    if $HAS_NVIDIA && [ "$VRAM_MB" -ge 8000 ] && [ "$RAM_GB" -ge 16 ]; then
        echo "dual"
    elif $HAS_NVIDIA && [ "$VRAM_MB" -ge 8000 ]; then
        echo "gpu"
    elif [ "$RAM_GB" -ge 12 ]; then
        echo "cpu"
    else
        echo "minimal"
    fi
}

# ── Display hardware ───────────────────────────────────────────────
show_hardware() {
    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║    Local Intelligence Configuration      ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${CYAN}Detected hardware:${NC}"
    echo -e "  CPU:    ${CPU_MODEL} (${CPU_CORES} threads)"

    local features=""
    $HAS_AVX2 && features="AVX2"
    $HAS_AVX512 && features="${features:+$features, }AVX-512"
    [ -n "$features" ] && echo -e "          ${DIM}$features${NC}"

    echo -e "  RAM:    ${RAM_GB} GB"

    if $HAS_NVIDIA; then
        echo -e "  GPU:    ${GREEN}${NVIDIA_GPU} (${VRAM_MB} MB VRAM)${NC}"
        if $HAS_NVIDIA_DOCKER; then
            echo -e "          ${GREEN}nvidia-container-toolkit detected${NC}"
        else
            echo -e "          ${YELLOW}nvidia-container-toolkit not detected${NC}"
            echo -e "          ${DIM}GPU profiles need: https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/${NC}"
        fi
    else
        echo -e "  GPU:    ${DIM}none detected${NC}"
    fi

    if $HAS_DOCKER; then
        echo -e "  Docker: ${GREEN}running${NC}"
    else
        echo -e "  Docker: ${RED}not available${NC}"
    fi
    echo ""
}

# ── Profile descriptions ──────────────────────────────────────────
show_profiles() {
    local recommended="$1"

    echo -e "${CYAN}Available profiles:${NC}"
    echo ""

    local tag
    for profile in dual gpu cpu minimal; do
        tag=""
        [ "$profile" = "$recommended" ] && tag=" ${GREEN}(recommended)${NC}"

        case "$profile" in
            dual)
                echo -e "  ${BOLD}1) dual${NC}${tag}"
                echo -e "     Falcon3 10B triage (CPU) + Qwen 3.5 9B synthesis (GPU)"
                echo -e "     ${DIM}Best quality. Needs: 16+ GB RAM, NVIDIA GPU 8+ GB VRAM${NC}"
                ;;
            gpu)
                echo -e "  ${BOLD}2) gpu${NC}${tag}"
                echo -e "     Qwen 3.5 9B only (GPU)"
                echo -e "     ${DIM}High quality, single model. Needs: NVIDIA GPU 8+ GB VRAM${NC}"
                ;;
            cpu)
                echo -e "  ${BOLD}3) cpu${NC}${tag}"
                echo -e "     Falcon3 10B only (CPU)"
                echo -e "     ${DIM}No GPU needed. Needs: 12+ GB RAM, AVX2${NC}"
                ;;
            minimal)
                echo -e "  ${BOLD}4) minimal${NC}${tag}"
                echo -e "     Falcon3 3B only (CPU)"
                echo -e "     ${DIM}Low resource. Needs: 4+ GB RAM${NC}"
                ;;
        esac
        echo ""
    done
}

# ── Write .env for selected profile ────────────────────────────────
write_env() {
    local profile="$1"

    # Preserve existing KNOWLEDGE_DIR if .env already exists
    local knowledge_dir="./data/knowledge"
    if [ -f "$ENV_FILE" ]; then
        existing=$(grep '^KNOWLEDGE_DIR=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- || true)
        [ -n "$existing" ] && knowledge_dir="$existing"
    fi

    # Preserve existing bind address and ports
    local bind_addr="127.0.0.1"
    local llm_port=8080 synth_port=8082 orch_port=8081 kiwix_port=8888 webui_port=3000
    if [ -f "$ENV_FILE" ]; then
        local v
        v=$(grep '^BIND_ADDR=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- || true); [ -n "$v" ] && bind_addr="$v"
        v=$(grep '^LLM_PORT=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- || true); [ -n "$v" ] && llm_port="$v"
        v=$(grep '^SYNTH_PORT=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- || true); [ -n "$v" ] && synth_port="$v"
        v=$(grep '^ORCHESTRATOR_PORT=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- || true); [ -n "$v" ] && orch_port="$v"
        v=$(grep '^KIWIX_PORT=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- || true); [ -n "$v" ] && kiwix_port="$v"
        v=$(grep '^WEBUI_PORT=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- || true); [ -n "$v" ] && webui_port="$v"
    fi

    # Profile-specific settings
    local pipeline_mode="single"
    local llm_url triage_url synth_url
    local falcon_ctx qwen_ctx falcon_mem threads rag_top_k

    threads=0
    rag_top_k=5

    case "$profile" in
        dual)
            pipeline_mode="dual"
            llm_url="http://falcon3:8080/v1/chat/completions"
            triage_url="http://falcon3:8080/v1/chat/completions"
            synth_url="http://qwen:8082/v1/chat/completions"
            falcon_ctx=16384   # triage needs less context
            falcon_mem="8g"
            qwen_ctx=8192
            ;;
        gpu)
            pipeline_mode="single"
            llm_url="http://qwen:8082/v1/chat/completions"
            triage_url=""
            synth_url=""
            falcon_ctx=32768
            falcon_mem="12g"
            qwen_ctx=8192
            ;;
        cpu)
            pipeline_mode="single"
            llm_url="http://falcon3:8080/v1/chat/completions"
            triage_url=""
            synth_url=""
            falcon_ctx=32768
            falcon_mem="12g"
            qwen_ctx=8192
            ;;
        minimal)
            pipeline_mode="single"
            llm_url="http://falcon3-mini:8080/v1/chat/completions"
            triage_url=""
            synth_url=""
            falcon_ctx=8192
            falcon_mem="4g"
            qwen_ctx=8192
            ;;
    esac

    # Check host ports and auto-reassign any that are occupied
    check_and_fix_ports "$profile"

    cat > "$ENV_FILE" <<EOF
# Local Intelligence — generated by configure.sh
# Profile: ${profile} | Pipeline: ${pipeline_mode}
# Re-run 'make setup' to reconfigure.

# ── Profile ─────────────────────────────────────────────────────────
COMPOSE_PROFILES=${profile}
PIPELINE_MODE=${pipeline_mode}

# ── Data directory ──────────────────────────────────────────────────
KNOWLEDGE_DIR=${knowledge_dir}

# ── Falcon3 (CPU) ──────────────────────────────────────────────────
FALCON_CTX_SIZE=${falcon_ctx}
FALCON_MEM_LIMIT=${falcon_mem}
THREADS=${threads}

# ── Qwen 3.5 (GPU) ─────────────────────────────────────────────────
QWEN_CTX_SIZE=${qwen_ctx}
QWEN_GPU_LAYERS=99

# ── LLM URLs ───────────────────────────────────────────────────────
LLM_URL=${llm_url}
TRIAGE_LLM_URL=${triage_url}
SYNTH_LLM_URL=${synth_url}

# ── Network binding ─────────────────────────────────────────────────
# 127.0.0.1 = localhost only (secure default)
# 0.0.0.0   = all interfaces (needed for LAN/multi-host access)
BIND_ADDR=${bind_addr}

# ── Ports ───────────────────────────────────────────────────────────
LLM_PORT=${llm_port}
SYNTH_PORT=${synth_port}
ORCHESTRATOR_PORT=${orch_port}
KIWIX_PORT=${kiwix_port}
WEBUI_PORT=${webui_port}

# ── RAG ─────────────────────────────────────────────────────────────
RAG_TOP_K=${rag_top_k}
EOF

    echo -e "${GREEN}Wrote .env for profile: ${BOLD}${profile}${NC}"
}

# ── Warn about missing GPU tooling ─────────────────────────────────
check_gpu_prereqs() {
    local profile="$1"
    case "$profile" in
        gpu|dual)
            if ! $HAS_NVIDIA; then
                echo -e "${RED}WARNING: No NVIDIA GPU detected. Profile '${profile}' requires one.${NC}"
                echo -e "${DIM}The Qwen container will fail to start without a GPU.${NC}"
                echo ""
            elif ! $HAS_NVIDIA_DOCKER; then
                echo -e "${YELLOW}WARNING: nvidia-container-toolkit not detected.${NC}"
                echo -e "${DIM}Install it for GPU access inside Docker containers.${NC}"
                echo ""
            fi
            ;;
    esac
}

# ── Main ───────────────────────────────────────────────────────────
main() {
    detect_hardware
    show_hardware

    local recommended
    recommended=$(recommend_profile)

    # Force profile from CLI
    if [ -n "$FORCE_PROFILE" ]; then
        case "$FORCE_PROFILE" in
            dual|gpu|cpu|minimal)
                check_gpu_prereqs "$FORCE_PROFILE"
                write_env "$FORCE_PROFILE"
                ;;
            *)
                echo -e "${RED}Unknown profile: $FORCE_PROFILE${NC}"
                echo "Valid profiles: cpu, gpu, dual, minimal"
                exit 1
                ;;
        esac
        return
    fi

    # Auto mode
    if $AUTO; then
        echo -e "Auto-selecting: ${BOLD}${recommended}${NC}"
        echo ""
        check_gpu_prereqs "$recommended"
        write_env "$recommended"
        return
    fi

    # Interactive
    show_profiles "$recommended"

    local choice
    read -rp "Select profile [1-4] (default: $recommended): " choice

    local profile
    case "${choice:-}" in
        1|dual)    profile="dual" ;;
        2|gpu)     profile="gpu" ;;
        3|cpu)     profile="cpu" ;;
        4|minimal) profile="minimal" ;;
        "")        profile="$recommended" ;;
        *)
            echo -e "${RED}Invalid choice: $choice${NC}"
            exit 1
            ;;
    esac

    echo ""
    check_gpu_prereqs "$profile"
    write_env "$profile"

    echo ""
    echo -e "Next steps:"
    echo -e "  ${CYAN}make build${NC}   Build Docker images for this profile"
    echo -e "  ${CYAN}make up${NC}      Start all services"
    echo -e "  ${CYAN}make health${NC}  Verify everything is running"
}

main
