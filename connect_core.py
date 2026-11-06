"""connect_core.py — 客户机上的远程终端内核（只绑 127.0.0.1，靠隧道出去）。

用法（用户不用手敲，connect.ps1 / connect.sh 会调）：
    python connect_core.py --key <随机串> --port 0 --ttl 14400 --root .

接口（全部要 header `X-Key: <key>`，否则 403）：
    GET  /ping                         -> {"ok":true,"root":..., "ttl":...}
    POST /exec   {"cmd","cwd","timeout"} -> {"ok","stdout","stderr","code"}
    GET  /ls?path=                     -> {"ok","items":[{name,dir,size}]}
    GET  /get?path=                    -> 文件原样（application/octet-stream）
    POST /put    {"path","b64"}        -> {"ok","bytes"}
    POST /shutdown                     -> {"ok":true}，进程退出

设计约束：无第三方依赖、单文件、日志落盘（不含 key）、TTL 到点自杀。
"""

from __future__ import annotations

import argparse
import base64
import hmac
import json
import os
import secrets
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

KEY = ""
ROOT = os.getcwd()
TTL = 14400
STARTED = time.time()
LOG_PATH = ""
MAX_BODY = 2 * 1024 * 1024
MAX_EXEC_SEC = 900


def log(event: str, **kw) -> None:
    rec = {"ts": time.strftime("%Y-%m-%d %H:%M:%S"), "event": event, **kw}
    line = json.dumps(rec, ensure_ascii=False)
    if LOG_PATH:
        with open(LOG_PATH, "a", encoding="utf-8") as f:
            f.write(line + "\n")


def safe_path(p: str) -> str:
    """限制在 ROOT 下；越界抛错（防止被当成任意文件读取器）。"""
    p = (p or ".").strip()
    full = os.path.abspath(os.path.join(ROOT, p.lstrip("\\/").replace("/", os.sep)))
    if full != ROOT and not full.startswith(ROOT + os.sep):
        raise PermissionError(f"path outside root: {p}")
    return full


class Handler(BaseHTTPRequestHandler):
    server_version = "xy-connect/1"
    protocol_version = "HTTP/1.1"

    # -- helpers ------------------------------------------------------
    def _json(self, obj: dict, code: int = 200) -> None:
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("content-type", "application/json; charset=utf-8")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _auth(self) -> bool:
        got = self.headers.get("x-key") or ""
        if not hmac.compare_digest(got, KEY):
            log("deny", path=self.path, ip=self.client_address[0])
            self._json({"ok": False, "error": "bad key"}, 403)
            return False
        if time.time() - STARTED > TTL:
            self._json({"ok": False, "error": "expired"}, 403)
            return False
        return True

    def _body(self) -> dict:
        n = int(self.headers.get("content-length") or 0)
        if n > MAX_BODY:
            raise ValueError("body too large")
        raw = self.rfile.read(n) if n else b"{}"
        return json.loads(raw.decode("utf-8", "replace") or "{}")

    def log_message(self, *a) -> None:  # 静音默认访问日志
        pass

    # -- routes -------------------------------------------------------
    def do_GET(self) -> None:
        if not self._auth():
            return
        u = urlparse(self.path)
        if u.path == "/ping":
            host = os.environ.get("COMPUTERNAME") or os.environ.get("HOSTNAME") or "unknown"
            return self._json({"ok": True, "root": ROOT,
                               "ttl_left": int(TTL - (time.time() - STARTED)), "host": host})
        if u.path == "/ls":
            try:
                p = safe_path(parse_qs(u.query).get("path", ["."])[0])
                items = [{"name": e.name, "dir": e.is_dir(), "size": (e.stat().st_size if e.is_file() else 0)}
                         for e in os.scandir(p)]
                items.sort(key=lambda x: (not x["dir"], x["name"].lower()))
                return self._json({"ok": True, "path": p, "items": items[:500]})
            except Exception as e:  # noqa: BLE001
                return self._json({"ok": False, "error": repr(e)}, 400)
        if u.path == "/get":
            try:
                p = safe_path(parse_qs(u.query).get("path", [""])[0])
                with open(p, "rb") as f:
                    data = f.read()
                self.send_response(200)
                self.send_header("content-type", "application/octet-stream")
                self.send_header("content-length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
                log("get", path=p, bytes=len(data))
                return None
            except Exception as e:  # noqa: BLE001
                return self._json({"ok": False, "error": repr(e)}, 400)
        return self._json({"ok": False, "error": "not found"}, 404)

    def do_POST(self) -> None:
        if not self._auth():
            return
        u = urlparse(self.path)
        try:
            data = self._body()
        except Exception as e:  # noqa: BLE001
            return self._json({"ok": False, "error": repr(e)}, 400)

        if u.path == "/exec":
            cmd = str(data.get("cmd") or "").strip()
            if not cmd:
                return self._json({"ok": False, "error": "empty cmd"}, 400)
            to = min(float(data.get("timeout") or 120), MAX_EXEC_SEC)
            cwd = safe_path(str(data.get("cwd") or "."))
            t0 = time.time()
            try:
                p = subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, timeout=to)
                out = p.stdout.decode("utf-8", "replace")
                err = p.stderr.decode("utf-8", "replace")
                log("exec", cmd=cmd[:200], code=p.returncode, ms=int((time.time() - t0) * 1000))
                return self._json({"ok": p.returncode == 0, "code": p.returncode,
                                   "stdout": out[-20000:], "stderr": err[-8000:],
                                   "ms": int((time.time() - t0) * 1000)})
            except subprocess.TimeoutExpired:
                log("exec_timeout", cmd=cmd[:200])
                return self._json({"ok": False, "error": "timeout", "sec": to}, 200)
            except Exception as e:  # noqa: BLE001
                return self._json({"ok": False, "error": repr(e)}, 500)

        if u.path == "/put":
            try:
                p = safe_path(str(data.get("path") or ""))
                blob = base64.b64decode(data.get("b64") or "", validate=False)
                os.makedirs(os.path.dirname(p) or ".", exist_ok=True)
                with open(p, "wb") as f:
                    f.write(blob)
                log("put", path=p, bytes=len(blob))
                return self._json({"ok": True, "path": p, "bytes": len(blob)})
            except Exception as e:  # noqa: BLE001
                return self._json({"ok": False, "error": repr(e)}, 400)

        if u.path == "/shutdown":
            self._json({"ok": True, "bye": True})
            log("shutdown")
            threading.Timer(0.3, lambda: os._exit(0)).start()
            return None

        return self._json({"ok": False, "error": "not found"}, 404)


def main() -> None:
    global KEY, ROOT, TTL, LOG_PATH
    ap = argparse.ArgumentParser()
    ap.add_argument("--key", default="")
    ap.add_argument("--port", type=int, default=0)
    ap.add_argument("--ttl", type=int, default=14400)
    ap.add_argument("--root", default=".")
    ap.add_argument("--log", default="")
    a = ap.parse_args()

    KEY = a.key or secrets.token_hex(16)
    ROOT = os.path.abspath(a.root)
    TTL = max(300, a.ttl)
    LOG_PATH = a.log or os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                     f"session-{time.strftime('%Y%m%d-%H%M%S')}.log")
    srv = ThreadingHTTPServer(("127.0.0.1", a.port), Handler)
    srv.daemon_threads = True
    port = srv.server_address[1]
    print(json.dumps({"ok": True, "port": port, "root": ROOT, "ttl": TTL,
                      "key_len": len(KEY), "log": LOG_PATH}, ensure_ascii=False), flush=True)
    log("start", port=port, root=ROOT, ttl=TTL)

    def reaper() -> None:
        while time.time() - STARTED < TTL:
            time.sleep(5)
        log("ttl_expired")
        os._exit(0)

    threading.Thread(target=reaper, daemon=True).start()
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        log("killed")
    finally:
        try:
            srv.server_close()
        except Exception:  # noqa: BLE001
            pass


if __name__ == "__main__":
    sys.exit(main())
