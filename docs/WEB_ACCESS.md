# Web Access: Open WebUI + Remote Access

Open WebUI gives you a ChatGPT-like web interface to your Local Intelligence
stack. Tailscale lets you reach it securely from your Surface, phone, or
anywhere — no port forwarding or dynamic DNS needed.

## Open WebUI Setup

Open WebUI connects to any OpenAI-compatible endpoint. We point it at the
orchestrator (port 8081), which handles RAG and LLM routing behind the scenes.
The orchestrator forwards to one or two LLMs depending on your profile (see
`ORCHESTRATOR.md` for details on single vs dual mode).

### Install via Docker (host networking — simplest on Linux)

With `--network=host`, the container shares the host's network stack directly.
Open WebUI's default internal port is 8080, so we override it with `PORT=3000`
to avoid colliding with Falcon3 on 8080.

```bash
docker run -d \
  --name open-webui \
  --restart always \
  --network=host \
  -v open-webui-data:/app/backend/data \
  -e OPENAI_API_BASE_URL=http://localhost:8081/v1 \
  -e OPENAI_API_KEY=local \
  -e WEBUI_AUTH=true \
  -e PORT=3000 \
  ghcr.io/open-webui/open-webui:main
```

Open WebUI is now at http://localhost:3000.

### Alternative: bridged networking (non-Linux or port isolation)

If you prefer explicit port mapping instead of host networking:

```bash
docker run -d \
  --name open-webui \
  --restart always \
  -p 3000:8080 \
  --add-host=host.docker.internal:host-gateway \
  -v open-webui-data:/app/backend/data \
  -e OPENAI_API_BASE_URL=http://host.docker.internal:8081/v1 \
  -e OPENAI_API_KEY=local \
  -e WEBUI_AUTH=true \
  ghcr.io/open-webui/open-webui:main
```

`--add-host=host.docker.internal:host-gateway` lets the container reach
host services. `-p 3000:8080` maps container port 8080 to host port 3000.

### Podman

```bash
podman run -d \
  --name open-webui \
  --restart always \
  --network=host \
  -v open-webui-data:/app/backend/data \
  -e OPENAI_API_BASE_URL=http://localhost:8081/v1 \
  -e OPENAI_API_KEY=local \
  -e WEBUI_AUTH=true \
  -e PORT=3000 \
  ghcr.io/open-webui/open-webui:main
```

### First Login

1. Browse to http://localhost:3000
2. Create an admin account on first visit
3. Go to **Admin Settings > Connections > OpenAI**
4. Verify the endpoint is `http://localhost:8081/v1` with key `local`
5. Select the `local-intelligence` model from the dropdown

## Remote Access via Tailscale

Tailscale creates a secure mesh VPN using WireGuard. Once installed on both
your desktop and your other devices, they can reach each other by hostname —
no port forwarding, no public IP exposure.

### Install Tailscale on the desktop

```bash
# Arch Linux
sudo pacman -S tailscale
sudo systemctl enable --now tailscaled
tailscale up

# Ubuntu / Debian
curl -fsSL https://tailscale.com/install.sh | sh
sudo systemctl enable --now tailscaled
tailscale up

# Follow the auth URL printed to link your account
```

### Install on your other devices

- **Surface (Arch)**: `sudo pacman -S tailscale && tailscale up`
- **Android/iOS**: Install Tailscale from your app store
- **Windows**: Download from https://tailscale.com/download

### Access from anywhere

Once both devices are on Tailscale, your desktop gets a hostname like
`desktop.tailnet-xxxx.ts.net` (or whatever you name it in the Tailscale
admin console).

From your Surface or phone:
- **Open WebUI**: `http://desktop:3000`
- **Kiwix browse**: `http://desktop:8888`
- **Falcon3 direct**: `http://desktop:8080/v1/chat/completions` (cpu/dual profiles)
- **Qwen direct**: `http://desktop:8082/v1/chat/completions` (gpu/dual profiles)
- **Orchestrator**: `http://desktop:8081/v1/chat/completions` (recommended — handles RAG)

All traffic is encrypted end-to-end via WireGuard. No data leaves your
Tailscale network.

### OpenCode on the Surface pointing at desktop

On the Surface, configure `~/.config/opencode/opencode.json`:

```json
{
  "providers": {
    "local-intelligence": {
      "name": "Local Intelligence (Desktop)",
      "baseURL": "http://desktop:8081/v1",
      "apiKey": "local"
    }
  }
}
```

Now OpenCode on the Surface uses the desktop's CPU for inference while
pulling context from the full knowledge base.

## Service Startup Order

All services should start automatically on boot via systemd:

```
local-fs.target
    |
    |-- kiwix-serve.service      (:8888)
    |-- falcon3-server.service   (:8080)   ← cpu/dual profiles
    '-- qwen-server.service      (:8082)   ← gpu/dual profiles
            |
            '-- orchestrator.service (:8081)

docker.service
    '-- open-webui container     (:3000)
```

### Verify everything is running

```bash
# Check all services
systemctl status kiwix-serve falcon3-server orchestrator

# Check Open WebUI container
docker ps | grep open-webui

# Quick health check
curl -s http://localhost:8080/v1/models  # Falcon3
curl -s http://localhost:8081/v1/models  # Orchestrator
curl -s http://localhost:8888            # Kiwix
curl -s http://localhost:3000            # Open WebUI
```

## Security Notes

- **Open WebUI auth is enabled** (`WEBUI_AUTH=true`) — create an account on
  first visit. This prevents unauthenticated access if someone finds the port.
- **Tailscale traffic is encrypted** — safe to use over public networks.
- **No services bind to 0.0.0.0 on the public interface** unless you want LAN
  access without Tailscale. If you do, consider firewall rules:

```bash
# Allow only LAN + Tailscale, block WAN (example for ufw)
sudo ufw allow from 192.168.0.0/16 to any port 3000
sudo ufw allow from 100.64.0.0/10 to any port 3000   # Tailscale CGNAT range
```
