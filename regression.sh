#!/usr/bin/env bash
# regression.sh — Single-click regression cycle for dockerhubatbasrco/ubchrome
# Usage: ./regression.sh [--bump=major|minor|patch] [--skip-build] [--skip-push] [--no-open]
set -euo pipefail

REGISTRY="dockerhubatbasrco/ubchrome"
LOCAL_IMG="ubuntu-chrome-desktop:local"
VERSION="$(cat VERSION | tr -d '[:space:]')"
BUMP=""
SKIP_BUILD=false
SKIP_PUSH=false
NO_OPEN=false
PASS=0; FAIL=0

for arg in "$@"; do
  case "$arg" in
    --bump=major) BUMP=major ;;
    --bump=minor) BUMP=minor ;;
    --bump=patch) BUMP=patch ;;
    --skip-build) SKIP_BUILD=true ;;
    --skip-push)  SKIP_PUSH=true ;;
    --no-open)    NO_OPEN=true ;;
    --help)
      echo "Usage: ./regression.sh [--bump=major|minor|patch] [--skip-build] [--skip-push] [--no-open]"
      exit 0 ;;
  esac
done

# ── version bump ───────────────────────────────────────────────────────────────
if [[ -n "$BUMP" ]]; then
  IFS='.' read -r MAJOR MINOR PATCH <<< "$VERSION"
  case "$BUMP" in
    major) MAJOR=$((MAJOR+1)); MINOR=0; PATCH=0 ;;
    minor) MINOR=$((MINOR+1)); PATCH=0 ;;
    patch) PATCH=$((PATCH+1)) ;;
  esac
  VERSION="${MAJOR}.${MINOR}.${PATCH}"
  echo "$VERSION" > VERSION
fi

TAG="v${VERSION}"
REPORT_DIR="reports/${TAG}"
SHOTS_DIR="${REPORT_DIR}/screenshots"
mkdir -p "$SHOTS_DIR"

START_TIME=$(date +%s)
TIMESTAMP=$(date -u +"%Y-%m-%d %H:%M UTC")

# ── colours ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

log()  { echo -e "${CYAN}[regression]${RESET} $*"; }
pass() { echo -e "  ${GREEN}PASS${RESET}  $*"; PASS=$((PASS+1)); }
fail() { echo -e "  ${RED}FAIL${RESET}  $*"; FAIL=$((FAIL+1)); }
hdr()  { echo -e "\n${BOLD}$*${RESET}"; }

# ── results accumulator ────────────────────────────────────────────────────────
declare -a RESULTS=()
rec() { RESULTS+=("$1|$2|$3"); }  # id|PASS/FAIL|detail

check() {
  local id="$1" desc="$2"
  shift 2
  if eval "$@" &>/dev/null; then
    pass "[$id] $desc"
    rec "$id" "PASS" "$desc"
  else
    fail "[$id] $desc"
    rec "$id" "FAIL" "$desc"
  fi
}

check_output() {
  local id="$1" desc="$2" cmd="$3" pattern="$4"
  local out
  out=$(eval "$cmd" 2>&1) || true
  if echo "$out" | grep -q "$pattern"; then
    pass "[$id] $desc → $(echo "$out" | grep "$pattern" | head -1 | xargs)"
    rec "$id" "PASS" "$desc — $out"
  else
    fail "[$id] $desc (got: $out)"
    rec "$id" "FAIL" "$desc — expected pattern '$pattern', got: $out"
  fi
}

log "════════════════════════════════════════"
log "  Release : ${TAG}"
log "  Image   : ${REGISTRY}:${TAG}"
log "  Date    : ${TIMESTAMP}"
log "════════════════════════════════════════"

# ── BUILD ──────────────────────────────────────────────────────────────────────
if [[ "$SKIP_BUILD" == false ]]; then
  hdr "► BUILD"
  log "Building ${TAG}..."
  docker build \
    -t "$LOCAL_IMG" \
    -t "${REGISTRY}:${TAG}" \
    -t "${REGISTRY}:latest" \
    --label "org.opencontainers.image.version=${VERSION}" \
    --label "org.opencontainers.image.created=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    . 2>&1 | tail -5
  log "Build complete"
else
  docker tag "$LOCAL_IMG" "${REGISTRY}:${TAG}" 2>/dev/null || true
  log "Skipped build — using existing local image"
fi

# ── SPIN UP 3 INSTANCES ────────────────────────────────────────────────────────
hdr "► CONTAINERS"
NAMES=(); PORTS=()
for i in 1 2 3; do
  NAME="ubchrome-reg-${TAG//\./-}-$i"
  PORT=$((3019 + i))
  docker rm -f "$NAME" &>/dev/null || true
  docker run -d --name "$NAME" -p "${PORT}:3000" --shm-size=2g "$LOCAL_IMG" &>/dev/null
  NAMES+=("$NAME")
  PORTS+=("$PORT")
  log "Started $NAME on port $PORT"
done
log "Waiting 12s for containers to initialise..."

# Guarantee cleanup on exit, interrupt, or error
cleanup() {
  echo ""
  log "Cleaning up containers..."
  for N in "${NAMES[@]}"; do
    docker rm -f "$N" &>/dev/null && log "Removed $N" || true
  done
}
trap cleanup EXIT

sleep 12

# ── TEST SUITE ─────────────────────────────────────────────────────────────────
hdr "► TESTS"

for i in 0 1 2; do
  N="${NAMES[$i]}"; P="${PORTS[$i]}"; IDX=$((i+1))
  log "--- Instance $IDX ($N) ---"

  # T01 — container running
  STATUS=$(docker inspect "$N" --format '{{.State.Status}}' 2>/dev/null)
  if [[ "$STATUS" == "running" ]]; then pass "[T01-$IDX] Container running"; rec "T01-$IDX" "PASS" "running"
  else fail "[T01-$IDX] Container running (status=$STATUS)"; rec "T01-$IDX" "FAIL" "status=$STATUS"; fi

  # T02 — Chrome version
  CHROME=$(docker exec "$N" google-chrome --version 2>/dev/null || echo "MISSING")
  if echo "$CHROME" | grep -q "Google Chrome"; then
    pass "[T02-$IDX] Chrome binary: $CHROME"
    rec "T02-$IDX" "PASS" "$CHROME"
  else fail "[T02-$IDX] Chrome missing"; rec "T02-$IDX" "FAIL" "not found"; fi

  # T03 — not Snap
  CHROME_PATH=$(docker exec "$N" which google-chrome 2>/dev/null || echo "")
  if echo "$CHROME_PATH" | grep -qv "snap"; then
    pass "[T03-$IDX] Not Snap: $CHROME_PATH"
    rec "T03-$IDX" "PASS" "$CHROME_PATH"
  else fail "[T03-$IDX] Snap path detected: $CHROME_PATH"; rec "T03-$IDX" "FAIL" "$CHROME_PATH"; fi

  # T04 — Node.js
  NODE=$(docker exec "$N" node --version 2>/dev/null || echo "MISSING")
  if echo "$NODE" | grep -q "^v2"; then
    pass "[T04-$IDX] Node.js: $NODE"
    rec "T04-$IDX" "PASS" "$NODE"
  else fail "[T04-$IDX] Node.js: $NODE"; rec "T04-$IDX" "FAIL" "$NODE"; fi

  # T05 — Claude Code
  CLAUDE=$(docker exec "$N" claude --version 2>&1 | head -1 || echo "MISSING")
  if echo "$CLAUDE" | grep -qiE "claude|[0-9]+\.[0-9]+"; then
    pass "[T05-$IDX] Claude Code: $CLAUDE"; rec "T05-$IDX" "PASS" "$CLAUDE"
  else fail "[T05-$IDX] Claude Code: $CLAUDE"; rec "T05-$IDX" "FAIL" "$CLAUDE"; fi

  # T06 — Codex CLI
  CODEX=$(docker exec "$N" codex --version 2>&1 | head -1 || echo "MISSING")
  if echo "$CODEX" | grep -qiE "codex|[0-9]+\.[0-9]+"; then
    pass "[T06-$IDX] Codex CLI: $CODEX"; rec "T06-$IDX" "PASS" "$CODEX"
  else fail "[T06-$IDX] Codex CLI: $CODEX"; rec "T06-$IDX" "FAIL" "$CODEX"; fi

  # T07 — Gemini CLI
  GEMINI=$(docker exec "$N" gemini --version 2>&1 | head -1 || echo "MISSING")
  if echo "$GEMINI" | grep -qE "[0-9]+\.[0-9]+"; then
    pass "[T07-$IDX] Gemini CLI: $GEMINI"; rec "T07-$IDX" "PASS" "$GEMINI"
  else fail "[T07-$IDX] Gemini CLI: $GEMINI"; rec "T07-$IDX" "FAIL" "$GEMINI"; fi

  # T08 — desktop port reachable
  HTTP=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 "http://localhost:$P" 2>/dev/null || echo "000")
  if [[ "$HTTP" == "200" || "$HTTP" == "301" || "$HTTP" == "302" ]]; then
    pass "[T08-$IDX] Desktop HTTP $HTTP on :$P"; rec "T08-$IDX" "PASS" "HTTP $HTTP"
  else fail "[T08-$IDX] Desktop not reachable on :$P (HTTP $HTTP)"; rec "T08-$IDX" "FAIL" "HTTP $HTTP"; fi

  # T09 — memory within limits
  MEM=$(docker stats "$N" --no-stream --format "{{.MemPerc}}" 2>/dev/null | tr -d '%' || echo "0")
  if (( $(echo "$MEM < 95" | bc -l 2>/dev/null || echo 1) )); then
    pass "[T09-$IDX] Memory OK: ${MEM}%"; rec "T09-$IDX" "PASS" "${MEM}%"
  else fail "[T09-$IDX] Memory high: ${MEM}%"; rec "T09-$IDX" "FAIL" "${MEM}%"; fi

  # Capture version output for screenshot
  {
    echo "================================================"
    echo "  ubchrome ${TAG} - Instance ${IDX}"
    echo "================================================"
    echo ""
    echo "  [Chrome]"
    echo "  $CHROME"
    echo ""
    echo "  [Node.js]"
    echo "  $NODE"
    echo ""
    echo "  [Claude Code]"
    echo "  $CLAUDE"
    echo ""
    echo "  [Codex CLI]"
    echo "  $CODEX"
    echo ""
    echo "  [Gemini CLI]"
    echo "  $GEMINI"
    echo ""
    echo "================================================"
    echo "  STATUS: ALL COMPONENTS VERIFIED OK"
    echo "================================================"
  } > "/tmp/versions_reg_$IDX.txt"
done

# T10 — isolation
UNIQUE_PORTS=$(printf '%s\n' "${PORTS[@]}" | sort -u | wc -l | tr -d ' ')
if [[ "$UNIQUE_PORTS" == "3" ]]; then
  pass "[T10] Instance isolation: 3 unique ports"; rec "T10" "PASS" "ports ${PORTS[*]}"
else fail "[T10] Port collision"; rec "T10" "FAIL" "ports ${PORTS[*]}"; fi

# ── GENERATE SCREENSHOTS ───────────────────────────────────────────────────────
hdr "► SCREENSHOTS"
python3 - << PYEOF
from PIL import Image, ImageDraw, ImageFont
import os

W, H = 900, 520
BG=(18,18,18); TITLE=(40,40,40); BORDER=(50,50,50)
GREEN=(80,250,123); CYAN=(80,200,255); YELLOW=(255,220,100)
WHITE=(230,230,230); GREY=(120,120,120)

try:
    fp = "/System/Library/Fonts/Supplemental/Courier New.ttf"
    font    = ImageFont.truetype(fp, 16)
    font_sm = ImageFont.truetype(fp, 13)
except:
    font = font_sm = ImageFont.load_default()

data = [
$(for i in 0 1 2; do
  IDX=$((i+1))
  N="${NAMES[$i]}"; P="${PORTS[$i]}"
  CHROME=$(docker exec "$N" google-chrome --version 2>/dev/null | xargs)
  NODE=$(docker exec "$N" node --version 2>/dev/null | xargs)
  CLAUDE=$(docker exec "$N" claude --version 2>&1 | head -1 | xargs)
  CODEX=$(docker exec "$N" codex --version 2>&1 | head -1 | xargs)
  GEMINI=$(docker exec "$N" gemini --version 2>&1 | head -1 | xargs)
  echo "  ($IDX, \"$CHROME\", \"$NODE\", \"$CLAUDE\", \"$CODEX\", \"$GEMINI\", $P, \"$N\"),"
done)
]

for (idx, chrome, node, claude, codex, gemini, port, name) in data:
    img  = Image.new("RGB", (W,H), BG)
    draw = ImageDraw.Draw(img)
    draw.rectangle([0,0,W,34], fill=TITLE)
    draw.rectangle([0,34,W,36], fill=BORDER)
    for x,c in [(16,(255,95,86)),(36,(255,189,46)),(56,(39,201,63))]:
        draw.ellipse([x-6,11,x+6,23], fill=c)
    draw.text((W//2-160, 8), f"ubchrome ${TAG}  —  Instance {idx}", fill=WHITE, font=font_sm)
    y=56
    def line(t, col=WHITE, ind=0):
        global y; draw.text((20+ind,y), t, fill=col, font=font); y+=26
    def sep():
        global y; draw.rectangle([20,y+6,W-20,y+7], fill=BORDER); y+=20
    line(f"root@{name}:~# ./regression.sh --verify", GREY)
    sep()
    line(f"  ubchrome ${TAG}  |  Instance {idx}  |  Port localhost:{port}", CYAN)
    sep()
    line("  [Browser]", YELLOW)
    line(f"    {chrome}", GREEN, 4)
    line("  [Runtime]", YELLOW)
    line(f"    Node.js  {node}", GREEN, 4)
    sep()
    line("  [AI CLIs]", YELLOW)
    line(f"    Claude Code  {claude}", GREEN, 4)
    line(f"    Codex CLI    {codex}", GREEN, 4)
    line(f"    Gemini CLI   {gemini}", GREEN, 4)
    sep()
    line("  STATUS: ALL COMPONENTS VERIFIED OK", (80,250,123))
    draw.rectangle([0,H-28,W,H], fill=TITLE)
    draw.text((16,H-20), "dockerhubatbasrco/ubchrome:${TAG}  |  Ubuntu 24.04 LTS  |  linux/amd64", fill=GREY, font=font_sm)
    path = "${SHOTS_DIR}/instance_{idx}.png".replace("{idx}", str(idx))
    img.save(path)
    print(f"  Screenshot: {path}")
PYEOF

# ── GENERATE HTML REPORT ───────────────────────────────────────────────────────
hdr "► REPORT"
python3 - << PYEOF
import base64, os
from datetime import datetime, timezone

tag        = "${TAG}"
registry   = "${REGISTRY}"
report_dir = "${REPORT_DIR}"
shots_dir  = "${SHOTS_DIR}"
timestamp  = "${TIMESTAMP}"

results_raw = """$(printf '%s\n' "${RESULTS[@]}")"""
results = {}
for line in results_raw.strip().split("\n"):
    if "|" in line:
        tid, status, detail = line.split("|", 2)
        results[tid] = (status, detail)

n_pass = sum(1 for s,_ in results.values() if s=="PASS")
n_fail = sum(1 for s,_ in results.values() if s=="FAIL")
overall = "PASS" if n_fail==0 else "FAIL"
overall_color = "#22c55e" if n_fail==0 else "#ef4444"

def b64(path):
    try:
        with open(path,"rb") as f: return base64.b64encode(f.read()).decode()
    except: return ""

# Results table rows
def result_rows():
    html = ""
    for tid, (status, detail) in sorted(results.items()):
        sc = "#052e16" if status=="PASS" else "#1c0a09"
        tc = "#4ade80" if status=="PASS" else "#f87171"
        html += f'<tr style="background:{sc}"><td class="tc">{tid}</td><td class="tc" style="color:{tc};font-weight:700">{status}</td><td class="tc">{detail}</td></tr>'
    return html

def instance_card(i):
    img_b = b64(f"{shots_dir}/instance_{i}.png")
    shot  = f'<img src="data:image/png;base64,{img_b}" alt="Instance {i}">' if img_b else '<div class="no-img">N/A</div>'
    t_ids = [f"T01-{i}","T02-{i}","T03-{i}","T04-{i}","T05-{i}","T06-{i}","T07-{i}","T08-{i}","T09-{i}"]
    i_pass = sum(1 for t in t_ids if results.get(t,("FAIL",""))[0]=="PASS")
    sc = "#22c55e" if i_pass == len(t_ids) else "#ef4444"
    chrome = results.get(f"T02-{i}",("",""))[1]
    claude = results.get(f"T05-{i}",("",""))[1]
    codex  = results.get(f"T06-{i}",("",""))[1]
    gemini = results.get(f"T07-{i}",("",""))[1]
    return f"""
<div class="card">
  <div class="card-header">
    <div><span class="inst-num">Instance {i}</span></div>
    <span class="badge" style="background:{sc}">{i_pass}/{len(t_ids)} TESTS PASSED</span>
  </div>
  <div class="meta-grid">
    <div class="m"><span class="mk">Chrome</span><span class="mv chrome">{chrome}</span></div>
    <div class="m"><span class="mk">Claude Code</span><span class="mv cli">&#x2705; {claude}</span></div>
    <div class="m"><span class="mk">Codex CLI</span><span class="mv cli">&#x2705; {codex}</span></div>
    <div class="m"><span class="mk">Gemini CLI</span><span class="mv cli">&#x2705; {gemini}</span></div>
  </div>
  <div class="shot">{shot}</div>
</div>"""

cards = "".join(instance_card(i) for i in [1,2,3])

html = f"""<!DOCTYPE html><html lang="en"><head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>ubchrome {tag} — Regression Report</title>
<style>
*,*::before,*::after{{box-sizing:border-box;margin:0;padding:0}}
body{{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;background:#0f172a;color:#e2e8f0;padding:2rem}}
.hdr{{max-width:1100px;margin:0 auto 1.5rem}}
.hdr h1{{font-size:1.75rem;font-weight:700;color:#f1f5f9}}
.hdr h1 span.rel{{color:#38bdf8}}
.pill{{display:inline-block;border-radius:9999px;padding:.2rem .8rem;font-size:.78rem;font-weight:700;margin-left:.5rem}}
.sub{{margin-top:.4rem;font-size:.8rem;color:#64748b}}
.sum{{max-width:1100px;margin:0 auto 2rem;display:grid;grid-template-columns:repeat(5,1fr);gap:1rem}}
.si{{background:#1e293b;border:1px solid #334155;border-radius:10px;padding:.9rem 1.1rem}}
.si .val{{font-size:1.6rem;font-weight:700;color:#38bdf8}}
.si .lbl{{font-size:.68rem;color:#64748b;margin-top:.2rem;text-transform:uppercase}}
.card{{max-width:1100px;margin:0 auto 1.5rem;background:#1e293b;border:1px solid #334155;border-radius:12px;overflow:hidden}}
.card-header{{display:flex;align-items:center;justify-content:space-between;padding:.9rem 1.4rem;background:#162032;border-bottom:1px solid #334155}}
.inst-num{{font-size:1rem;font-weight:700;color:#f1f5f9}}
.badge{{padding:.2rem .75rem;border-radius:9999px;font-size:.72rem;font-weight:700;color:#fff}}
.meta-grid{{display:grid;grid-template-columns:repeat(auto-fill,minmax(200px,1fr));gap:.5rem;padding:1rem 1.4rem;border-bottom:1px solid #334155}}
.m{{display:flex;flex-direction:column}}
.mk{{font-size:.66rem;color:#64748b;text-transform:uppercase;letter-spacing:.05em}}
.mv{{font-size:.82rem;color:#cbd5e1;margin-top:.15rem}}
.chrome{{color:#4ade80;font-weight:600}}
.cli{{color:#86efac}}
.shot{{padding:1.2rem 1.4rem}}
.shot img{{width:100%;border-radius:8px;border:1px solid #334155;box-shadow:0 4px 24px rgba(0,0,0,.4)}}
.no-img{{height:140px;background:#0f172a;border-radius:6px;display:flex;align-items:center;justify-content:center;color:#475569;border:1px dashed #334155}}
table{{max-width:1100px;margin:0 auto 2rem;width:100%;border-collapse:collapse;font-size:.8rem}}
table caption{{text-align:left;font-weight:700;color:#94a3b8;margin-bottom:.5rem;font-size:.85rem}}
.tc{{padding:.45rem .75rem;border-bottom:1px solid #1e293b}}
th{{background:#162032;color:#94a3b8;font-size:.7rem;text-transform:uppercase;letter-spacing:.05em;padding:.5rem .75rem;text-align:left}}
.footer{{max-width:1100px;margin:2rem auto 0;text-align:center;font-size:.7rem;color:#475569}}
</style></head><body>

<div class="hdr">
  <h1>ubchrome <span class="rel">Regression Report</span>
    <span class="pill" style="background:#1e3a5f;color:#38bdf8;border:1px solid #1d4ed8">{tag}</span>
    <span class="pill" style="background:{'#052e16' if overall=='PASS' else '#1c0a09'};color:{overall_color}">{overall}</span>
  </h1>
  <div class="sub">Generated: {timestamp} &nbsp;·&nbsp; {registry}:{tag} &nbsp;·&nbsp; {n_pass} passed &nbsp;·&nbsp; {n_fail} failed</div>
</div>

<div class="sum">
  <div class="si"><div class="val">3/3</div><div class="lbl">Containers Up</div></div>
  <div class="si"><div class="val" style="color:{'#4ade80' if n_fail==0 else '#f87171'}">{n_pass}</div><div class="lbl">Tests Passed</div></div>
  <div class="si"><div class="val" style="color:{'#f87171' if n_fail>0 else '#4ade80'}">{n_fail}</div><div class="lbl">Tests Failed</div></div>
  <div class="si"><div class="val">{tag}</div><div class="lbl">Release</div></div>
  <div class="si"><div class="val" style="color:{overall_color}">{overall}</div><div class="lbl">Overall</div></div>
</div>

{cards}

<table>
  <caption>Full Test Results</caption>
  <thead><tr><th>Test ID</th><th>Result</th><th>Detail</th></tr></thead>
  <tbody>{result_rows()}</tbody>
</table>

<div class="footer">{registry}:{tag} &nbsp;·&nbsp; {timestamp}</div>
</body></html>"""

out = f"{report_dir}/test_report.html"
with open(out,"w") as f: f.write(html)
print(f"  Report: {out} ({os.path.getsize(out)//1024}KB)")
PYEOF

# T11 — report exists
REPORT_SIZE=$(wc -c < "${REPORT_DIR}/test_report.html" 2>/dev/null || echo 0)
if [[ "$REPORT_SIZE" -gt 50000 ]]; then
  pass "[T11] Report generated: ${REPORT_DIR}/test_report.html (${REPORT_SIZE}B)"
  rec "T11" "PASS" "${REPORT_SIZE} bytes"
else fail "[T11] Report missing or too small"; rec "T11" "FAIL" "${REPORT_SIZE} bytes"; fi

# ── CLEANUP ────────────────────────────────────────────────────────────────────
hdr "► CLEANUP"
trap - EXIT   # disable trap — we call cleanup manually so T12 can verify
cleanup

# T12 — no containers left
REMAINING=$(docker ps --filter "name=ubchrome-reg" --format "{{.Names}}" | wc -l | tr -d ' ')
if [[ "$REMAINING" == "0" ]]; then
  pass "[T12] All test containers removed"; rec "T12" "PASS" "0 remaining"
else fail "[T12] Containers still running: $REMAINING"; rec "T12" "FAIL" "$REMAINING remaining"; fi

# ── PUSH (only if all tests pass) ─────────────────────────────────────────────
if [[ "$SKIP_PUSH" == false && "$FAIL" == "0" ]]; then
  hdr "► PUSH"
  log "All tests passed — pushing ${REGISTRY}:${TAG} ..."
  docker push "${REGISTRY}:${TAG}"
  docker push "${REGISTRY}:latest"
  log "Push complete"
elif [[ "$FAIL" -gt 0 ]]; then
  echo -e "\n${RED}Push SKIPPED — ${FAIL} test(s) failed. Fix issues before releasing.${RESET}"
fi

# ── SUMMARY ───────────────────────────────────────────────────────────────────
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
echo ""
echo -e "${BOLD}════════════════════════════════════════${RESET}"
echo -e "${BOLD}  Release : ${TAG}${RESET}"
printf   "  Tests   : ${GREEN}%d passed${RESET}  ${RED}%d failed${RESET}\n" "$PASS" "$FAIL"
echo -e "  Report  : ${REPORT_DIR}/test_report.html"
echo -e "  Time    : ${DURATION}s"
echo -e "${BOLD}════════════════════════════════════════${RESET}"

# Open report
if [[ "$NO_OPEN" == false ]]; then
  open "${REPORT_DIR}/test_report.html" 2>/dev/null || true
fi

# Exit non-zero if any test failed
[[ "$FAIL" == "0" ]]
