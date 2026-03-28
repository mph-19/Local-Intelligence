# Docker Beginner Guide

If you've never used Docker before, this guide will get you running. Docker
packages the entire application — code, models, dependencies — into isolated
**containers** that run the same way on any machine. Think of it like a
lightweight virtual machine for each service.

## Key Concepts

- **Image**: A snapshot of everything a service needs to run (code, libraries,
  model files). Built once, reused on every start.
- **Container**: A running instance of an image. Starting a container is like
  booting a pre-configured machine — it takes seconds, not minutes.
- **Volume**: A folder shared between your computer and a container. This is
  how the containers access your knowledge base files without bundling them
  into the image.
- **Compose**: A tool that starts multiple containers together from a single
  config file (`docker-compose.yml`). Instead of starting each service
  manually, one command brings up the whole stack.
- **Profile**: A label on a service that controls whether it starts. Local
  Intelligence uses profiles to select which LLM(s) to run based on your
  hardware. See [Profiles](#profiles) below.

## Requirements

- **Docker Compose v2.20+** — needed for profile-aware service ordering.
  Docker Desktop ships with a recent Compose. Check with: `docker compose version`

## Option 1: Docker Desktop (GUI)

Docker Desktop is available for **Windows**, **macOS**, and **Linux**. It gives
you a graphical interface for managing containers.

1. **Install Docker Desktop** from https://www.docker.com/products/docker-desktop/
2. **Open Docker Desktop** and let it finish starting (the whale icon in your
   system tray/menu bar will stop animating when ready)
3. **Allocate enough memory**: Go to **Settings > Resources > Advanced** and
   set Memory to at least **12 GB** (or 6 GB if using the `minimal` profile).
   Click **Apply & Restart**.
4. **Open a terminal** (Terminal on macOS/Linux, PowerShell on Windows) and
   navigate to this project:
   ```bash
   cd path/to/local-intelligence
   ```
5. **Run the setup wizard and start**:
   ```bash
   make setup    # detects your hardware and picks the right config
   make build    # builds the Docker images (~5-15 min on first run)
   make up       # starts all services
   ```
6. **Open the chat interface** at http://localhost:3000
   **Register immediately** — the first account becomes admin. Signup is
   disabled by default after the first user registers.

In Docker Desktop you can now see all running containers under the
**Containers** tab. You can view logs, stop/restart individual services, and
monitor resource usage from the GUI.

## Option 2: Docker CLI

If you prefer the command line or are running on a headless server, you only
need the Docker Engine (no Desktop GUI). Here's the full sequence:

```bash
# 1. Clone the repository
git clone https://github.com/YOUR_USER/local-intelligence.git
cd local-intelligence

# 2. Run the setup wizard — detects your hardware (CPU, RAM, GPU)
#    and writes a .env file with the right profile and settings.
#    Profiles: cpu, gpu, dual, minimal (see .env.example for details)
make setup

# 3. Build the Docker images
#    Downloads model files and compiles inference engines inside the image.
#    Only slow the first time (~5-15 min). Rebuilds are cached and fast.
make build

# 4. Start all services in the background
#    -d means "detached" — containers run in the background, not in your terminal.
make up

# 5. Check that everything came up healthy
#    Shows [OK] or [FAIL] for each service.
make health

# 6. Open the chat interface
#    Visit http://localhost:3000 in your browser.
#    First login creates an admin account.
#    Signup is disabled after the first user registers (by default).
```

## What Each Command Does

| You type | What actually runs | What it does |
|---|---|---|
| `make setup` | `bash scripts/configure.sh` | Detects hardware, asks which profile, writes `.env` |
| `make build` | `docker compose build` | Builds images for each service (downloads models, compiles code) |
| `make up` | `docker compose up -d` | Creates and starts all containers in the background |
| `make down` | `docker compose down` | Stops and removes all containers (data is preserved) |
| `make health` | `curl` to each service | Checks each service is responding |
| `make logs` | `docker compose logs -f` | Streams live logs from all containers (Ctrl+C to stop) |
| `make status` | `docker compose ps` | Shows which containers are running and their ports |

## Profiles

Profiles control which LLM services start based on your hardware. The setup
wizard (`make setup`) picks the right one automatically, but you can also set
it manually in `.env`.

| Profile | LLM(s) started | Requirements |
|---|---|---|
| `cpu` | Falcon3 10B (CPU) | 12+ GB RAM, AVX2 CPU |
| `gpu` | Qwen 3.5 9B (GPU) | NVIDIA GPU with 8+ GB VRAM |
| `dual` | Falcon3 (CPU) + Qwen 3.5 (GPU) | 16+ GB RAM + NVIDIA GPU 8+ GB VRAM |
| `minimal` | Falcon3 3B (CPU) | 4+ GB RAM |

In `dual` mode, Falcon3 acts as a fast triage filter (scoring and filtering
retrieved chunks on CPU) while Qwen 3.5 handles the final synthesis (reasoning
and generating the answer on GPU). The orchestrator manages this automatically.

To change profiles:
```bash
make setup              # re-run the wizard
# or edit .env directly:
#   COMPOSE_PROFILES=dual
#   PIPELINE_MODE=dual
make down && make up    # restart with new profile
```

## Common Situations

**"I want to start over"** — If something goes wrong and you want a clean slate:
```bash
make down       # stop everything
make clean      # remove built images (keeps your data)
make build      # rebuild from scratch
make up         # start fresh
```

**"I changed the .env file"** — After editing `.env` (or re-running `make setup`):
```bash
make down && make up    # restart with new settings
```

**"How do I see what's happening?"** — Watch logs from all services:
```bash
make logs       # streams all logs, Ctrl+C to stop watching
```

**"It says port 3000 is already in use"** — Another application is using that
port. Edit `.env` and change `WEBUI_PORT=3000` to a free port (e.g. `3001`),
then restart.

**"How do I update to the latest version?"** — Pull the latest code and rebuild:
```bash
git pull
make build      # rebuilds only changed images
make down && make up
```

## Prerequisites Checklist

Before running `make up`, make sure:

- [ ] **Docker is installed and running** — `docker ps` should work without errors.
      If you get "permission denied", add yourself to the docker group:
      `sudo usermod -aG docker $USER` then log out and back in.
- [ ] **Enough RAM is allocated** — Docker Desktop defaults to 2-4 GB, which is
      not enough. Set it to 12+ GB in Settings > Resources. On Linux, Docker
      uses system RAM directly so this isn't an issue.
- [ ] **GPU profiles need nvidia-container-toolkit** — If using `gpu` or `dual`
      profile, install the NVIDIA Container Toolkit:
      https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/

## Local vs Multi-Machine Setup

By default, all services bind to **localhost only** (`127.0.0.1`). This means
only the machine running Docker can access them — other devices on your network
cannot. This is the secure default.

### Single machine (default)

Everything runs on one machine. You access Open WebUI at `http://localhost:3000`.
No network configuration needed — it just works out of the box.

```
Your machine
  ├── Falcon3    (localhost:8080)   ← only you can reach these
  ├── Orchestrator (localhost:8081)
  ├── Kiwix      (localhost:8888)
  └── Open WebUI (localhost:3000)   ← open this in your browser
```

### Accessing from other devices on your network

If you want to reach Open WebUI from your phone, tablet, or another computer
on the same WiFi/LAN, you need to open the ports to your network. Edit `.env`
and change one variable:

```bash
# .env
BIND_ADDR=0.0.0.0    # listen on all network interfaces
```

Then restart:
```bash
make down && make up
```

Now other devices can reach the services at your machine's IP address (e.g.
`http://192.168.1.100:3000`). **Be aware**: this exposes all services to your
local network. On a trusted home network this is fine. On a shared or public
network, keep the default `127.0.0.1`.

### Multi-machine deployment

For running services across multiple machines (e.g. LLM on a powerful desktop,
Kiwix on a NAS), see **[MULTI_HOST.md](MULTI_HOST.md)**. You'll need:

1. `BIND_ADDR=0.0.0.0` on each machine that hosts a service
2. Environment variables pointing services at each other's IPs/hostnames
3. Optionally, Caddy as a reverse proxy and Tailscale for secure remote access

### Binding to a specific interface

If you use Tailscale, you can bind only to the Tailscale interface instead of
all interfaces:

```bash
# .env — only reachable over Tailscale, not the LAN
BIND_ADDR=100.x.y.z    # your Tailscale IP
```

This gives you remote access without exposing services on the local network.

## Port Map

These are the default ports. All are configurable in `.env`. Ports bind to
`127.0.0.1` (localhost only) unless `BIND_ADDR` is changed.

| Service | Port | When active |
|---|---|---|
| Falcon3 (CPU LLM) | 8080 | `cpu`, `dual`, `minimal` profiles |
| Qwen 3.5 (GPU LLM) | 8082 | `gpu`, `dual` profiles |
| Orchestrator | 8081 | Always (main entry point) |
| Kiwix | 8888 | Always |
| Open WebUI | 3000 | Always |
