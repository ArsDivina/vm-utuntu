# ubchrome — Containerized Ubuntu Desktop with Chrome + AI CLIs

A production-ready Docker image providing a full Ubuntu XFCE desktop environment with Google Chrome (native `.deb`, no Snap), accessible via browser, and pre-loaded with Claude Code, Codex CLI, and Gemini CLI.

**Docker Hub:** `dockerhubatbasrco/ubchrome:latest`

---

## What's Inside

| Component | Version | Notes |
|---|---|---|
| Base OS | Ubuntu 24.04 LTS | XFCE desktop via linuxserver/webtop |
| Google Chrome | 147+ | Official `.deb`, no Snap confinement |
| ChromeDriver | Bundled | For WebDriver-based test harnesses |
| Claude Code | 2.1.96+ | Anthropic's AI coding CLI |
| Codex CLI | 0.118.0+ | OpenAI's Codex CLI |
| Gemini CLI | 0.37.0+ | Google's Gemini CLI |
| Node.js | 22 LTS | Runtime for all AI CLIs |
| Desktop Access | Port 3000 | Browser-based (no VNC client needed) |

---

## Quick Start

```bash
docker run -d \
  --name ubchrome \
  -p 3000:3000 \
  --shm-size=2g \
  dockerhubatbasrco/ubchrome:latest
```

Open **http://localhost:3000** in your browser — full XFCE desktop appears.

---

## Docker Compose (single instance)

```yaml
services:
  ubchrome:
    image: dockerhubatbasrco/ubchrome:latest
    platform: linux/amd64
    ports:
      - "3000:3000"
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=America/New_York
      - ANTHROPIC_API_KEY=your_key_here   # Claude Code
      - OPENAI_API_KEY=your_key_here      # Codex CLI
      - GEMINI_API_KEY=your_key_here      # Gemini CLI
    shm_size: 2g
    restart: unless-stopped
    mem_limit: 2g
    cpus: 1.0
```

## Scale to Multiple Instances

```bash
docker compose up -d --scale ubchrome=3
# Instances available at localhost:3010, 3011, 3012
```

Use a port range in compose for multi-instance:

```yaml
ports:
  - "3010-3012:3000"
```

---

## Using the AI CLIs

Open a terminal inside the desktop (`right-click → Terminal`) and run:

```bash
# Claude Code — AI pair programmer
claude

# OpenAI Codex CLI
codex

# Google Gemini CLI
gemini
```

API keys can be set via environment variables (see compose above) or entered interactively on first run.

---

## Chrome for Automated Testing

Chrome is installed as a native `.deb` with no Snap sandbox, making it suitable for test harnesses.

### Headless automation (inside container)

```bash
google-chrome \
  --no-sandbox \
  --headless \
  --disable-gpu \
  --remote-debugging-port=9222 \
  https://example.com
```

### Remote debugging from host

Expose the debug port in compose:

```yaml
ports:
  - "3000:3000"
  - "9222:9222"
```

Then connect Puppeteer, Playwright, or Selenium from your host to `localhost:9222`.

### ChromeDriver / Selenium

```bash
# Inside container
chromedriver --port=4444 &
```

---

## Platform Notes

| Host | Behaviour |
|---|---|
| **x86_64 Linux** (production) | Native speed, full Chrome GUI + headless |
| **Apple Silicon (ARM64)** | Runs via QEMU emulation — Chrome binary works, GUI rendering limited |

For local Mac development, use Chromium (ARM64 native) and reserve this image for x86_64 servers.

---

## Build from Source

```bash
git clone <this-repo>
cd vm-ubuntu

# Build
docker build -t ubchrome:local .

# Run
docker compose up -d
```

### Dockerfile overview

```
webtop:ubuntu-xfce          ← XFCE desktop + browser access on :3000
  └── google-chrome-stable  ← Official .deb from dl.google.com
  └── nodejs 22 + npm       ← Runtime for AI CLIs
      ├── @anthropic-ai/claude-code
      ├── @openai/codex
      └── @google/gemini-cli
```

---

## Volumes

| Mount | Purpose |
|---|---|
| `/config` | Persists Chrome profile, desktop settings, home directory |

```yaml
volumes:
  - chrome-data:/config
```

---

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `PUID` | `1000` | User ID for file permissions |
| `PGID` | `1000` | Group ID for file permissions |
| `TZ` | `America/New_York` | Container timezone |
| `ANTHROPIC_API_KEY` | — | Pre-configures Claude Code |
| `OPENAI_API_KEY` | — | Pre-configures Codex CLI |
| `GEMINI_API_KEY` | — | Pre-configures Gemini CLI |

---

## Reports

Test reports are generated in `reports/test_report.html` with per-instance screenshots, Chrome version verification, and click/navigation test results.

```bash
python3 reports/generate_report.py
open reports/test_report.html
```
