#!/usr/bin/env bash
set -euo pipefail

REGISTRY="dockerhubatbasrco/ubchrome"
VERSION="$(cat VERSION | tr -d '[:space:]')"
TAG="v${VERSION}"

# ── helpers ────────────────────────────────────────────────────────────────────
log()  { echo "[release] $*"; }
die()  { echo "[release] ERROR: $*" >&2; exit 1; }

# ── parse flags ────────────────────────────────────────────────────────────────
SKIP_BUILD=false
SKIP_PUSH=false
SKIP_REPORT=false
BUMP=""          # major | minor | patch

for arg in "$@"; do
  case "$arg" in
    --skip-build)  SKIP_BUILD=true ;;
    --skip-push)   SKIP_PUSH=true ;;
    --skip-report) SKIP_REPORT=true ;;
    --bump=major)  BUMP=major ;;
    --bump=minor)  BUMP=minor ;;
    --bump=patch)  BUMP=patch ;;
    --help)
      echo "Usage: ./release.sh [--bump=major|minor|patch] [--skip-build] [--skip-push] [--skip-report]"
      exit 0 ;;
    *) die "Unknown argument: $arg" ;;
  esac
done

# ── optional version bump ───────────────────────────────────────────────────────
if [[ -n "$BUMP" ]]; then
  IFS='.' read -r MAJOR MINOR PATCH <<< "$VERSION"
  case "$BUMP" in
    major) MAJOR=$((MAJOR+1)); MINOR=0; PATCH=0 ;;
    minor) MINOR=$((MINOR+1)); PATCH=0 ;;
    patch) PATCH=$((PATCH+1)) ;;
  esac
  VERSION="${MAJOR}.${MINOR}.${PATCH}"
  TAG="v${VERSION}"
  echo "$VERSION" > VERSION
  log "Version bumped → ${TAG}"
fi

log "═══════════════════════════════════════"
log "  Release: ${TAG}"
log "  Image:   ${REGISTRY}:${TAG}"
log "═══════════════════════════════════════"

# ── build ──────────────────────────────────────────────────────────────────────
if [[ "$SKIP_BUILD" == false ]]; then
  log "Building image..."
  docker build \
    -t "ubuntu-chrome-desktop:local" \
    -t "${REGISTRY}:${TAG}" \
    -t "${REGISTRY}:latest" \
    --label "org.opencontainers.image.version=${VERSION}" \
    --label "org.opencontainers.image.created=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --label "org.opencontainers.image.title=ubchrome" \
    --label "org.opencontainers.image.description=Ubuntu XFCE + Chrome .deb + Claude Code + Codex CLI + Gemini CLI" \
    .
  log "Build complete: ${REGISTRY}:${TAG}"
else
  # Still apply version tags to the existing local image
  docker tag ubuntu-chrome-desktop:local "${REGISTRY}:${TAG}"
  docker tag ubuntu-chrome-desktop:local "${REGISTRY}:latest"
  log "Skipped build — tagged existing local image as ${TAG}"
fi

# ── push ───────────────────────────────────────────────────────────────────────
if [[ "$SKIP_PUSH" == false ]]; then
  log "Pushing ${REGISTRY}:${TAG} ..."
  docker push "${REGISTRY}:${TAG}"
  log "Pushing ${REGISTRY}:latest ..."
  docker push "${REGISTRY}:latest"
  log "Push complete"
else
  log "Skipped push"
fi

# ── versioned test report ──────────────────────────────────────────────────────
if [[ "$SKIP_REPORT" == false ]]; then
  REPORT_DIR="reports/${TAG}"
  SCREENSHOTS_DIR="${REPORT_DIR}/screenshots"
  mkdir -p "$SCREENSHOTS_DIR"
  log "Generating report in ${REPORT_DIR}/ ..."

  # Spin up 3 containers for this release
  export UBCHROME_VERSION="$TAG"
  docker compose up -d --scale ubchrome=3 2>/dev/null
  log "Waiting for containers to be ready..."
  sleep 8

  # Collect metadata from each instance
  python3 - <<PYEOF
import subprocess, base64, os, json
from datetime import datetime, timezone

version  = "${VERSION}"
tag      = "${TAG}"
registry = "${REGISTRY}"
report_dir = "${REPORT_DIR}"
screenshots_dir = "${SCREENSHOTS_DIR}"

instances = []
for i in [1, 2, 3]:
    name = f"vm-ubuntu-ubchrome-{i}"
    def docker(*args):
        r = subprocess.run(["docker"] + list(args), capture_output=True, text=True)
        return r.stdout.strip()

    status  = docker("inspect", name, "--format", "{{.State.Status}}")
    img     = docker("inspect", name, "--format", "{{.Config.Image}}")
    started = docker("inspect", name, "--format", "{{.State.StartedAt}}")
    port    = docker("port", name)
    chrome  = docker("exec", name, "google-chrome", "--version")
    node    = docker("exec", name, "node", "--version")
    claude  = docker("exec", name, "claude", "--version")
    codex   = docker("exec", name, "codex", "--version")
    gemini  = docker("exec", name, "gemini", "--version")
    mem     = docker("stats", name, "--no-stream", "--format", "{{.MemUsage}}")
    os_     = docker("exec", name, "bash", "-c", "grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '\"'")
    host_port = port.split("->")[1].replace("0.0.0.0:","").strip().split("\n")[0] if port else "N/A"

    instances.append({
        "id": i, "name": name, "status": status, "image": img,
        "started": started, "host_port": host_port,
        "chrome": chrome, "node": node,
        "claude": claude.split("\n")[0],
        "codex": codex.split("\n")[0],
        "gemini": gemini.split("\n")[0],
        "mem": mem, "os": os_,
    })

# Take screenshots via xwd for each instance
converter = "/tmp/xwd2png.py"
for inst in instances:
    i   = inst["id"]
    nm  = inst["name"]
    # copy converter
    subprocess.run(["docker", "cp", converter, f"{nm}:/tmp/xwd2png.py"])
    # screenshot
    subprocess.run(["docker", "exec", nm, "bash", "-c",
                    f"DISPLAY=:1 xwd -root -silent > /tmp/shot_{i}.xwd"], capture_output=True)
    subprocess.run(["docker", "exec", nm, "python3", "/tmp/xwd2png.py",
                    f"/tmp/shot_{i}.xwd", f"/tmp/shot_{i}.png"], capture_output=True)
    subprocess.run(["docker", "cp", f"{nm}:/tmp/shot_{i}.png",
                    f"{screenshots_dir}/instance_{i}.png"])

def b64(path):
    try:
        with open(path, "rb") as f: return base64.b64encode(f.read()).decode()
    except: return ""

def card(inst):
    i    = inst["id"]
    sc   = "#22c55e" if inst["status"] == "running" else "#ef4444"
    img  = b64(f"{screenshots_dir}/instance_{i}.png")
    shot = f'<img src="data:image/png;base64,{img}" alt="Instance {i} desktop">' if img else \
           '<div class="no-img">Screenshot unavailable</div>'
    clis = [
        ("Claude Code", inst["claude"]),
        ("Codex CLI",   inst["codex"]),
        ("Gemini CLI",  inst["gemini"]),
    ]
    cli_rows = "".join(
        f'<div class="meta-item"><span class="meta-key">{n}</span>'
        f'<span class="meta-val cli-ok">✅ {v}</span></div>'
        for n, v in clis
    )
    return f"""
<div class="card">
  <div class="card-header">
    <div><span class="inst-num">Instance {i}</span>
         <span class="container-name">{inst["name"]}</span></div>
    <span class="badge" style="background:{sc}">{inst["status"].upper()}</span>
  </div>
  <div class="meta-grid">
    <div class="meta-item"><span class="meta-key">Chrome</span>
      <span class="meta-val chrome-ver">{inst["chrome"]}</span></div>
    <div class="meta-item"><span class="meta-key">OS</span>
      <span class="meta-val">{inst["os"]}</span></div>
    <div class="meta-item"><span class="meta-key">Node.js</span>
      <span class="meta-val">{inst["node"]}</span></div>
    <div class="meta-item"><span class="meta-key">Image</span>
      <span class="meta-val mono">{inst["image"]}</span></div>
    <div class="meta-item"><span class="meta-key">Desktop Port</span>
      <span class="meta-val port">localhost:{inst["host_port"]}</span></div>
    <div class="meta-item"><span class="meta-key">Memory</span>
      <span class="meta-val">{inst["mem"]}</span></div>
    {cli_rows}
  </div>
  <div class="shot-wrap">{shot}</div>
</div>"""

now   = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
cards = "".join(card(i) for i in instances)
all_running = all(i["status"] == "running" for i in instances)

html = f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>ubchrome {tag} — Test Report</title>
<style>
*,*::before,*::after{{box-sizing:border-box;margin:0;padding:0}}
body{{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;background:#0f172a;color:#e2e8f0;padding:2rem}}
.header{{max-width:1100px;margin:0 auto 1.5rem}}
.header h1{{font-size:1.75rem;font-weight:700;color:#f1f5f9}}
.header h1 span{{color:#38bdf8}}
.header .sub{{margin-top:.4rem;font-size:.82rem;color:#64748b}}
.tag-pill{{display:inline-block;background:#1e3a5f;color:#38bdf8;border:1px solid #1d4ed8;
           border-radius:9999px;padding:.2rem .8rem;font-size:.8rem;font-weight:700;margin-left:.5rem}}
.summary{{max-width:1100px;margin:0 auto 2rem;
          display:grid;grid-template-columns:repeat(5,1fr);gap:1rem}}
.s-item{{background:#1e293b;border:1px solid #334155;border-radius:10px;padding:.9rem 1.1rem}}
.s-item .val{{font-size:1.6rem;font-weight:700;color:#38bdf8}}
.s-item .lbl{{font-size:.7rem;color:#64748b;margin-top:.2rem;text-transform:uppercase}}
.card{{max-width:1100px;margin:0 auto 1.5rem;background:#1e293b;
       border:1px solid #334155;border-radius:12px;overflow:hidden}}
.card-header{{display:flex;align-items:center;justify-content:space-between;
              padding:1rem 1.5rem;background:#162032;border-bottom:1px solid #334155}}
.inst-num{{font-size:1rem;font-weight:700;color:#f1f5f9;margin-right:.6rem}}
.container-name{{font-size:.8rem;color:#64748b;font-family:monospace}}
.badge{{padding:.2rem .7rem;border-radius:9999px;font-size:.72rem;font-weight:700;color:#fff}}
.meta-grid{{display:grid;grid-template-columns:repeat(auto-fill,minmax(220px,1fr));
            gap:.5rem;padding:1rem 1.5rem;border-bottom:1px solid #334155}}
.meta-item{{display:flex;flex-direction:column}}
.meta-key{{font-size:.68rem;color:#64748b;text-transform:uppercase;letter-spacing:.05em}}
.meta-val{{font-size:.82rem;color:#cbd5e1;margin-top:.1rem}}
.chrome-ver{{color:#4ade80;font-weight:600}}
.cli-ok{{color:#86efac}}
.port{{color:#38bdf8;font-family:monospace}}
.mono{{font-family:monospace;font-size:.78rem}}
.shot-wrap{{padding:1.2rem 1.5rem}}
.shot-wrap img{{width:100%;border-radius:6px;border:1px solid #334155}}
.no-img{{height:160px;background:#0f172a;border-radius:6px;display:flex;
         align-items:center;justify-content:center;color:#475569;font-size:.8rem;
         border:1px dashed #334155}}
.footer{{max-width:1100px;margin:2rem auto 0;text-align:center;
         font-size:.72rem;color:#475569}}
</style>
</head>
<body>
<div class="header">
  <h1>ubchrome <span>Test Report</span> <span class="tag-pill">{tag}</span></h1>
  <div class="sub">
    Generated: {now} &nbsp;·&nbsp;
    Image: {registry}:{tag} &nbsp;·&nbsp;
    Chrome: {instances[0]["chrome"].replace("Google Chrome ", "")} &nbsp;·&nbsp;
    Overall: {"✅ PASS" if all_running else "❌ FAIL"}
  </div>
</div>
<div class="summary">
  <div class="s-item"><div class="val">{sum(1 for i in instances if i["status"]=="running")}/3</div><div class="lbl">Containers Up</div></div>
  <div class="s-item"><div class="val">{instances[0]["chrome"].split()[-1]}</div><div class="lbl">Chrome Version</div></div>
  <div class="s-item"><div class="val">3</div><div class="lbl">AI CLIs</div></div>
  <div class="s-item"><div class="val">.deb</div><div class="lbl">Install Method</div></div>
  <div class="s-item"><div class="val">{tag}</div><div class="lbl">Release</div></div>
</div>
{cards}
<div class="footer">{registry}:{tag} &nbsp;·&nbsp; {now}</div>
</body></html>"""

report_path = f"{report_dir}/test_report.html"
with open(report_path, "w") as f: f.write(html)
print(f"Report: {report_path} ({os.path.getsize(report_path)//1024}KB)")
PYEOF

  # Tear containers down after report
  docker compose down 2>/dev/null
  log "Containers stopped"
  log "Report → ${REPORT_DIR}/test_report.html"
  open "${REPORT_DIR}/test_report.html" 2>/dev/null || true
else
  log "Skipped report"
fi

log "═══════════════════════════════════════"
log "  Done: ${REGISTRY}:${TAG}"
log "═══════════════════════════════════════"
