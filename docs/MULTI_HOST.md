# Multi-Host Deployment

Run Local Intelligence as a self-hosted web service where components are
distributed across multiple machines on your network. A reverse proxy
(Caddy) fronts everything under a single hostname.

## Why Multi-Host?

A single desktop can run all services, but distributing lets you:
- Put LLM inference on the machine with the most CPU cores / RAM / GPU
- In dual mode, run Falcon3 (CPU triage) and Qwen (GPU synthesis) on different hosts
- Put Kiwix + ZIM files on a NAS with large storage
- Run the reverse proxy on an always-on low-power device (Pi, NUC)
- Keep Open WebUI on whatever machine you want the Docker overhead on
- Scale by adding machines instead of replacing hardware

## Network Architecture

```
                Internet / Tailscale
                        |
              +---------v----------+
              |   Gateway Host     |
              |   (Caddy :443)     |
              |   always-on box    |
              +--+-----+-----+----+
                 |     |     |
     +-----------+  +--+--+  +----------+
     |              |     |             |
+----v-----+  +----v--+  +---v----+  +--v--------+
| Desktop  |  | NAS / |  | Any   |  | Desktop   |
| Inference|  | Store |  | Host  |  | or same   |
|          |  |       |  |       |  | machine   |
| Falcon3  |  | Kiwix |  | Open  |  | Orchestr. |
| :8080    |  | :8888 |  | WebUI |  | :8081     |
| Qwen     |  | ZIMs  |  | :3000 |  | RAG/Qdrant|
| :8082    |  |       |  |       |  |           |
+----------+  +-------+  +-------+  +-----------+
```

All hosts must be reachable from each other. Tailscale handles this
automatically — each machine gets a stable hostname like `desktop.ts.net`,
`nas.ts.net`, etc.

## Caddy Reverse Proxy

Caddy is the front door. It provides:
- Single hostname for all services (`intelligence.local` or a Tailscale domain)
- Automatic HTTPS with Let's Encrypt (or self-signed for LAN)
- Path-based routing to backends on any host
- Transparent proxying — clients hit one URL, Caddy routes internally

### Install Caddy

```bash
# Arch Linux
sudo pacman -S caddy

# Ubuntu / Debian
sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | \
  sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | \
  sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo apt update && sudo apt install caddy

# Fedora
sudo dnf install caddy
```

### Caddyfile: Single Machine

All services on one host. The simplest configuration.

```
# /etc/caddy/Caddyfile

intelligence.local {
    # Chat UI — default route
    handle / {
        reverse_proxy localhost:3000
    }
    handle /static/* {
        reverse_proxy localhost:3000
    }

    # OpenAI-compatible API (orchestrator with RAG)
    handle /v1/* {
        reverse_proxy localhost:8081
    }

    # Kiwix knowledge browser
    handle /kiwix/* {
        uri strip_prefix /kiwix
        reverse_proxy localhost:8888
    }

    # Falcon3 direct (bypass orchestrator)
    handle /falcon3/* {
        uri strip_prefix /falcon3
        reverse_proxy localhost:8080
    }

    # Open WebUI catches everything else
    handle {
        reverse_proxy localhost:3000
    }
}
```

For LAN-only with no real domain, use:
```
:80 {
    # same handle blocks as above
}
```

### Caddyfile: Multi-Host

Services split across machines. Replace hostnames with your Tailscale names
or LAN IPs.

```
# /etc/caddy/Caddyfile

intelligence.local {
    # Chat UI on webui-host
    handle {
        reverse_proxy webui-host:3000
    }

    # Orchestrator + RAG on orchestrator-host
    handle /v1/* {
        reverse_proxy orchestrator-host:8081
    }

    # Kiwix on nas (where the ZIMs live)
    handle /kiwix/* {
        uri strip_prefix /kiwix
        reverse_proxy nas:8888
    }

    # Falcon3 on inference-host (most CPU cores / RAM)
    handle /falcon3/* {
        uri strip_prefix /falcon3
        reverse_proxy inference-host:8080
    }
}
```

### Start Caddy

```bash
sudo systemctl enable --now caddy
sudo systemctl status caddy

# Reload after editing Caddyfile
sudo systemctl reload caddy
```

## Network Binding

By default, all Docker ports bind to `127.0.0.1` (localhost only). For
multi-host deployments, each machine hosting a service must set:

```bash
# .env on each host
BIND_ADDR=0.0.0.0
```

This allows other machines on the network to reach the service. If you use
Tailscale, you can bind to the Tailscale IP instead (e.g. `BIND_ADDR=100.x.y.z`)
to avoid exposing services on the local LAN.

## Service Configuration for Multi-Host

Each service needs to know how to reach the others. Use environment variables
so the same code runs on any topology.

### Orchestrator

The orchestrator is the only service that needs to find the LLM, Kiwix, and Qdrant.
Set via environment or systemd:

```ini
# /etc/systemd/system/orchestrator.service
[Service]
Environment=LLM_URL=http://inference-host:8080/v1/chat/completions
Environment=ORCHESTRATOR_PORT=8081
ExecStart=/usr/bin/python3 /knowledge/services/orchestrator.py
```

If Qdrant runs on the same host as the orchestrator (recommended — embedded
mode reads local disk), no extra config is needed.

### Falcon3 (LLM)

Falcon3 is stateless — it just serves inference on CPU. Run it on whichever
machine has the most cores and RAM. It doesn't need to reach any other service.

```ini
# /etc/systemd/system/falcon3-server.service on inference-host
[Service]
ExecStart=/knowledge/services/bitnet-cpp/build/bin/llama-server \
  --model /knowledge/services/bitnet-cpp/models/Falcon3-10B-Instruct-1.58bit/ggml-model-i2_s.gguf \
  --host 0.0.0.0 --port 8080 \
  --n-gpu-layers 0 --ctx-size 32768 --threads 8
```

### Kiwix

Kiwix is read-only and stateless. Run it on whichever machine has the ZIM
files (a NAS with large storage is ideal).

```ini
# /etc/systemd/system/kiwix-serve.service on nas
[Service]
ExecStart=/usr/bin/kiwix-serve --library /knowledge/kiwix-library.xml \
  --port 8888 --nodatealias
```

### Open WebUI

Open WebUI needs to reach the orchestrator. Configure via its API URL:

```bash
# On webui-host
docker run -d \
  --name open-webui \
  --restart always \
  --network=host \
  -v open-webui-data:/app/backend/data \
  -e OPENAI_API_BASE_URL=http://orchestrator-host:8081/v1 \
  -e OPENAI_API_KEY=local \
  -e WEBUI_AUTH=true \
  -e PORT=3000 \
  ghcr.io/open-webui/open-webui:main
```

## Example Deployments

### Minimal: Everything on the Desktop

```
Desktop (10900K, 32GB RAM):
  - Falcon3 10B   :8080  (CPU)
  - Kiwix         :8888
  - Orchestrator  :8081
  - Open WebUI    :3000
  - Caddy         :80
```

One machine, all services. This is the simplest setup and where you should
start. Move services off later if you need to.

### Two-Machine: Desktop + NAS

```
Desktop (10900K, 32GB):           NAS (always-on, large storage):
  - Falcon3 10B   :8080 (CPU)       - Kiwix         :8888
  - Orchestrator  :8081             - Caddy         :80
  - Open WebUI    :3000
```

ZIM files live on the NAS where storage is cheap. Caddy on the NAS is the
always-on entry point. The orchestrator on the desktop sets
`KIWIX_URL=http://nas:8888` (used by ingestion scripts only — at query time
the orchestrator reads from local Qdrant, not Kiwix).

### Three-Machine: Desktop + NAS + Surface

```
Desktop (CPU):     NAS (storage):     Surface (mobile):
  - Falcon3 :8080    - Kiwix :8888      - OpenCode client
  - Orchestr :8081   - Caddy :80          (points at desktop:8081)
  - Open WebUI       - ZIMs on disk
  - Qdrant
```

The Surface runs nothing server-side — it's purely a client, reaching the
desktop's orchestrator over Tailscale.

## DNS and Hostname Resolution

### Option A: Tailscale MagicDNS (recommended)

Tailscale assigns stable hostnames automatically:
```
desktop.tailnet-xxxx.ts.net
nas.tailnet-xxxx.ts.net
```

These work from any device on your Tailscale network. No configuration needed.

### Option B: /etc/hosts (LAN only)

Add entries on each machine:
```
192.168.1.100  desktop inference-host
192.168.1.200  nas
192.168.1.150  surface
```

### Option C: Local DNS (Pi-hole, Unbound, etc.)

If you already run local DNS, add A records:
```
intelligence.local  -> 192.168.1.100  (or wherever Caddy runs)
```

## Health Monitoring

A simple script to check all services across hosts:

```bash
#!/usr/bin/env bash
# scripts/healthcheck.sh — run from any machine on the network

GATEWAY="${1:-localhost}"  # pass Caddy host as argument

echo "=== Local Intelligence Health Check ==="

check() {
    local name="$1" url="$2"
    if curl -sf --max-time 5 "$url" > /dev/null 2>&1; then
        echo "  [OK]   $name"
    else
        echo "  [FAIL] $name ($url)"
    fi
}

check "Caddy proxy"   "http://$GATEWAY/"
check "Open WebUI"    "http://$GATEWAY:3000/"
check "Orchestrator"  "http://$GATEWAY:8081/v1/models"
check "Falcon3"       "http://$GATEWAY:8080/v1/models"
check "Kiwix"         "http://$GATEWAY:8888/"

echo ""
echo "Done."
```

## Full Port Reference

All Docker services bind to `BIND_ADDR` (default `127.0.0.1`). For multi-host,
set `BIND_ADDR=0.0.0.0` in `.env` on each host.

| Service | Port | Host | Accessed by |
|---|---|---|---|
| Caddy | 80/443 | Gateway | All clients |
| Open WebUI | 3000 | Any | Caddy, direct |
| Orchestrator | 8081 | Desktop | Open WebUI, Caddy, OpenCode |
| Falcon3 | 8080 | Inference host (CPU) | Orchestrator |
| Kiwix | 8888 | NAS/Desktop | Caddy (browsing), ingestion scripts |
| Qdrant | N/A | Same as Orchestrator | Orchestrator (in-process, embedded) |

## Adding a New Service Host

1. Install Tailscale on the new machine
2. Move the relevant systemd service and its data to the new machine
3. Update the Caddyfile to point at the new hostname
4. Update any `Environment=` lines in dependent services
5. `sudo systemctl reload caddy`
6. Run `scripts/healthcheck.sh` to verify
