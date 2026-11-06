#!/usr/bin/env bash
# connect.sh — 客户机一键接入（macOS / Linux）
# 用法： curl -fsSL <镜像>/connect.sh | bash
# 或：   bash connect.sh [key] [ttl_sec]
set -euo pipefail

REPO="liuzekun666393/xy-hub"          # ← 改成实际仓库
ROOT="${HOME}"
TTL="${2:-14400}"
KEY="${1:-}"
WORK="${TMPDIR:-/tmp}/xy_boot"
mkdir -p "$WORK"

UA="Mozilla/5.0 (X11; Linux x86_64) xy-boot/2"
LINES=(
  "https://xy.example.com/{path}"
  "https://ghproxy.net/https://raw.githubusercontent.com/${REPO}/main/{path}"
  "https://ghfast.top/https://raw.githubusercontent.com/${REPO}/main/{path}"
  "https://cdn.jsdelivr.net/gh/${REPO}@main/{path}"
  "https://raw.githubusercontent.com/${REPO}/main/{path}"
)

say() { printf '\033[1;36m%s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m%s\033[0m\n' "$*"; }

get_file() { # $1=path $2=out
  for tpl in "${LINES[@]}"; do
    url="${tpl//\{path\}/$1}"
    if curl -fsSL --max-time 25 -A "$UA" -o "$2" "$url" 2>/dev/null && [ -s "$2" ]; then
      warn "[line] $url"
      return 0
    fi
    warn "[line] 失败: $url"
  done
  return 1
}

[ -z "$KEY" ] && KEY="$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n' | cut -c1-32)"

say "== 闲鱼装机器 · 接入 =="

get_file "bootstrap/connect_core.py" "$WORK/connect_core.py" || { echo "内核拉不到，换个网络再试"; exit 1; }

PY="$(command -v python3 || command -v python || true)"
if [ -z "$PY" ]; then
  warn "没找到 python3，请先装（apt install python3 / brew install python）"
  exit 1
fi

# 本机内核
nohup "$PY" "$WORK/connect_core.py" --key "$KEY" --port 0 --ttl "$TTL" --root "$ROOT" \
  > "$WORK/core.out" 2> "$WORK/core.err" &
CORE_PID=$!
sleep 2
PORT="$(grep -o '"port": *[0-9]\+' "$WORK/core.out" | grep -o '[0-9]\+' | head -1 || true)"
if [ -z "$PORT" ]; then
  warn "本地终端没起来："; tail -5 "$WORK/core.err" || true; exit 1
fi
say "本地终端 127.0.0.1:$PORT  root=$ROOT"

curl -fsS -H "X-Key: $KEY" "http://127.0.0.1:$PORT/ping" && echo

# 隧道
OS="$(uname -s)"; ARCH="$(uname -m)"
if [ "$OS" = "Darwin" ]; then
  CF_NAME="cloudflared-darwin-amd64"; command -v brew >/dev/null && brew list cloudflared >/dev/null 2>&1 || true
elif [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then
  CF_NAME="cloudflared-linux-arm64"
else
  CF_NAME="cloudflared-linux-amd64"
fi
CF="$WORK/cloudflared"
if [ ! -x "$CF" ] && ! command -v cloudflared >/dev/null; then
  get_file "bootstrap/bin/${CF_NAME}" "$CF" || { echo "cloudflared 拉不到"; exit 1; }
  chmod +x "$CF"
elif command -v cloudflared >/dev/null; then
  CF="$(command -v cloudflared)"
fi

LOG="$WORK/cloudflared.log"
: > "$LOG"
"$CF" tunnel --url "http://127.0.0.1:$PORT" --no-autoupdate --logfile "$LOG" &
CF_PID=$!

HOST=""
for _ in $(seq 1 60); do
  sleep 1
  HOST="$(grep -Eo 'https://[a-z0-9-]+\.trycloudflare\.com' "$LOG" | head -1 || true)"
  [ -n "$HOST" ] && break
done
if [ -z "$HOST" ]; then
  warn "隧道没起来，日志尾部："; tail -10 "$LOG" || true
  kill "$CORE_PID" "$CF_PID" 2>/dev/null || true
  exit 1
fi
HOST="${HOST#https://}"

echo
printf '\033[1;32m==== 把下面这一行原样发我 ====\033[0m\n'
printf '\033[1;32mxy1://%s/%s\033[0m\n' "$HOST" "$KEY"
printf '\033[1;32m==============================\033[0m\n'
warn "有效期 $((TTL / 3600)) 小时；Ctrl-C 断开。"

cleanup() { kill "$CORE_PID" "$CF_PID" 2>/dev/null || true; warn "会话结束，隧道已关闭。"; }
trap cleanup EXIT INT TERM
wait "$CORE_PID"
