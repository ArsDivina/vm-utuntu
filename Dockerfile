FROM --platform=linux/amd64 lscr.io/linuxserver/webtop:ubuntu-xfce

# Install Google Chrome from official .deb (x86_64 only — requires amd64 platform)
RUN apt-get update && apt-get install -y wget ca-certificates --no-install-recommends \
  && wget -q https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb \
  && apt-get install -y ./google-chrome-stable_current_amd64.deb --no-install-recommends \
  && rm google-chrome-stable_current_amd64.deb \
  && rm -rf /var/lib/apt/lists/* \
  # Convenience aliases so 'chrome' and 'google-chrome' both work
  && ln -sf /usr/bin/google-chrome-stable /usr/local/bin/chrome \
  && ln -sf /usr/bin/google-chrome-stable /usr/local/bin/google-chrome

# Install Node.js 22 LTS + AI CLIs (Claude Code, Codex CLI, Gemini CLI)
RUN apt-get update && apt-get install -y curl --no-install-recommends \
  && curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
  && apt-get install -y nodejs \
  && rm -rf /var/lib/apt/lists/* \
  && npm install -g \
      @anthropic-ai/claude-code \
      @openai/codex \
      @google/gemini-cli \
  && npm cache clean --force

# Catalyst Edge Node — runtime deps pre-installed at /app/edge/node_modules
# Source is bind-mounted at /app/edge/src at runtime from the darkfleet repo
RUN mkdir -p /app/edge /var/lib/catalyst-edge/sessions \
  && cd /app/edge \
  && npm init -y \
  && npm install --save \
      express@^4.18.2 \
      uuid@^9.0.1 \
      ws@^8.17.0 \
      ioredis@^5.3.2 \
  && npm cache clean --force \
  && chmod 700 /var/lib/catalyst-edge

# Pre-create config dirs so CLIs don't error on first run before volume mounts
# webtop maps /config as the home volume — we seed the structure here
RUN mkdir -p /config/.gemini \
  && mkdir -p /config/.claude \
  && mkdir -p /config/.codex \
  && echo '{}' > /config/.gemini/projects.json

# Bake a /version.txt into the image for quick verification
ARG BUILD_DATE
RUN echo "ubchrome $(cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2 | tr -d '\"')" > /version.txt \
  && echo "Chrome: $(google-chrome --version 2>/dev/null || echo 'installed')" >> /version.txt \
  && echo "Node:   $(node --version)" >> /version.txt \
  && echo "Claude: $(claude --version 2>&1 | head -1)" >> /version.txt \
  && echo "Codex:  $(codex --version 2>&1 | head -1)" >> /version.txt \
  && echo "Gemini: $(gemini --version 2>&1 | head -1)" >> /version.txt \
  && echo "Edge:   deps installed (express uuid ws ioredis) — src bind-mounted at runtime" >> /version.txt \
  && cat /version.txt
