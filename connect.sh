#!/usr/bin/env bash
# connect.sh — 客户机接入（Linux / macOS）
set -uo pipefail

REPO="liuzekun666393/xy-hub"
TTL="${2:-14400}"
KEY="${1:-$(head -c 16 /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n' || echo xy$(date +%s))}"
DIR="${TMPDIR:-/tmp}/xy_boot"
mkdir -p "$DIR"

BASE=(
  "https://raw.githubusercontent.com/${REPO}/main"
  "https://ghproxy.net/https://raw.githubusercontent.com/${REPO}/main"
  "https://ghfast.top/https://raw.githubusercontent.com/${REPO}/main"
  "https://cdn.jsdelivr.net/gh/${REPO}@main"
)

fetch() {
  for b in "${BASE[@]}"; do
    if curl -fsSL --max-time 25 -o "$2" "$b/$1" 2>/dev/null && [ -s "$2" ]; then return 0; fi
  done
  return 1
}

fetch connect_core.py "$DIR/connect_core.py" || { echo "ERR=download_core"; exit 1; }

PY="$(command -v python3 || command -v python || true)"
[ -z "$PY" ] && { echo "ERR=no_python"; exit 1; }

"$PY" "$DIR/connect_core.py" --key "$KEY" --port 0 --ttl "$TTL" --root "$HOME" \
  > "$DIR/core.out" 2> "$DIR/core.err" &
CORE_PID=$!
sleep 2

PORT="$(grep -o '"port": *[0-9]\+' "$DIR/core.out" 2>/dev/null | grep -o '[0-9]\+' | head -1)"
[ -z "$PORT" ] && { echo "ERR=core_start"; tail -3 "$DIR/core.err" 2>/dev/null; exit 1; }

echo "PORT=$PORT"
echo "KEY=$KEY"

# 隧道：优先本机 cloudflared，没有就下载
CF="$(command -v cloudflared 2>/dev/null || true)"
if [ -z "$CF" ]; then
  OS="$(uname -s)"; ARCH="$(uname -m)"
  case "$OS$ARCH" in
    Darwin*) CF_NAME="cloudflared-darwin-amd64" ;;
    *aarch64*|*arm64*) CF_NAME="cloudflared-linux-arm64" ;;
    *) CF_NAME="cloudflared-linux-amd64" ;;
  esac
  CF="$DIR/cloudflared"
  if [ ! -x "$CF" ]; then
    for u in \
      "https://ghproxy.net/https://github.com/cloudflare/cloudflared/releases/latest/download/${CF_NAME}" \
      "https://github.com/cloudflare/cloudflared/releases/latest/download/${CF_NAME}"; do
      curl -fsSL --max-time 120 -o "$CF" "$u" 2>/dev/null && [ -s "$CF" ] && break
    done
    chmod +x "$CF" 2>/dev/null
  fi
  [ -x "$CF" ] || { echo "ERR=no_cloudflared"; kill "$CORE_PID" 2>/dev/null; exit 1; }
fi

LOG="$DIR/cf.log"; : > "$LOG"
"$CF" tunnel --url "http://127.0.0.1:$PORT" --no-autoupdate --logfile "$LOG" >/dev/null 2>&1 &
CF_PID=$!

HOST=""
for _ in $(seq 1 60); do
  sleep 1
  HOST="$(grep -Eo 'https://[a-z0-9-]+\.trycloudflare\.com' "$LOG" 2>/dev/null | head -1)"
  [ -n "$HOST" ] && break
done
[ -z "$HOST" ] && { echo "ERR=no_tunnel"; kill "$CORE_PID" "$CF_PID" 2>/dev/null; exit 1; }

echo "URL=$HOST"
echo "TTL=$TTL"

cleanup() { kill "$CORE_PID" "$CF_PID" 2>/dev/null; }
trap cleanup EXIT INT TERM
wait "$CORE_PID"
