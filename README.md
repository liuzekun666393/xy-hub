# bootstrap — 客户机接入（隧道 + 随机密钥）

> 客户不需要懂技术：把**一行命令**贴进 PowerShell / 终端，回车，把打印出来的
> `xy1://HOST/KEY` 发给我，我就能连上去装。

## 1. 文件

| 文件 | 作用 |
| --- | --- |
| `connect.ps1` | Windows 一键：选线路 → 下内核 → 起本地终端 → cloudflared 隧道 → 打印配对串 |
| `connect.sh` | macOS / Linux 同上 |
| `connect_core.py` | 客户机上的终端内核：只绑 `127.0.0.1`，`X-Key` 鉴权，TTL 到点自杀，命令落日志 |
| `relay.json` | 线路表（镜像/反代），脚本按它测速选线 |
| `bin/cloudflared-*` | 隧道客户端（随仓库放，避免客户现场下载失败） |

## 2. 给客户的两行命令

**Windows**
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "$u='https://ghproxy.net/https://raw.githubusercontent.com/liuzekun666393/xy-hub/main/connect.ps1'; iwr -UseBasicParsing $u -OutFile $env:TEMP\xy.ps1; & $env:TEMP\xy.ps1"
```

**macOS / Linux**
```bash
curl -fsSL https://ghproxy.net/https://raw.githubusercontent.com/liuzekun666393/xy-hub/main/connect.sh | bash
```

> 国内直连 GitHub 基本不通，所以命令里**默认就带镜像**。脚本内部还会按 `relay.json`
> 依次试 self → ghproxy → ghfast → jsdelivr → raw，取第一个通的。

## 3. 线路（镜像 / 反代）

| id | 类型 | 说明 |
| --- | --- | --- |
| `self` | 自建反代 | **上线后放第一位**，最稳（nginx 反代 raw.githubusercontent.com） |
| `ghproxy` | 公共加速 | 国内多数可用，偶尔 5xx |
| `ghfast` | 公共加速 | 备用 |
| `jsdelivr` | CDN | 只适合文本，二进制不稳 |
| `raw` | 源站 | 直连，多数不通 |

自建反代最小配置：

```nginx
location /xy/ {
    proxy_pass https://raw.githubusercontent.com/liuzekun666393/xy-hub/main/;
    proxy_set_header Host raw.githubusercontent.com;
    proxy_ssl_server_name on;
    add_header Cache-Control "no-store";
}
```

## 4. 密钥与生命周期

- 每次运行生成 **16 字节随机 key**（32 hex），只打印一次；4 小时（`--ttl`）后自动退出。
- 隧道是**临时**的（`trycloudflare.com`），关窗口即断，不留常驻。
- `connect_core.py` 只接受 `127.0.0.1` 连接；外网只能通过隧道 + key 进来。
- 客户机日志：`%TEMP%\xy_boot\session-*.log`（或 `/tmp/xy_boot/`），只记命令与返回值，
  **不记 key**。装完提醒客户可以整个删掉 `xy_boot`。

## 5. 装完的收尾（必须做）

```powershell
# Windows
taskkill /im cloudflared.exe /f
Remove-Item -Recurse -Force "$env:TEMP\xy_boot"
```
```bash
# macOS / Linux
pkill -f cloudflared; rm -rf "${TMPDIR:-/tmp}/xy_boot"
```

## 6. 排错

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| 所有线路失败 | 网络/DNS | 让客户开手机热点重跑 |
| 打印 `本地终端没起来` | 没装 Python | 脚本会试 `winget`；失败就让客户装官网包 |
| 卡在 `隧道没起来` | cloudflared 被墙/被拦 | 换线路重下 `bin/cloudflared-*`；或客户网络限制出站 |
| 配对串能发但连不上 | key 过期/打错 | 重跑一次，key 一次一换 |
| 客户端提示脚本被拦 | PowerShell 执行策略 | 用命令里的 `-ExecutionPolicy Bypass` |

## 7. 待操作者提供（阻塞）

- [ ] GitHub 账号 + 仓库名（替换两处 `liuzekun666393/xy-hub`）+ 可推送的 token（PAT）
- [ ] 是否已有域名可做反代（`xy.example.com`），有则填进 `relay.json` 的 `self`
- [ ] `cloudflared` 二进制是否允许入仓（体积 ~35MB/个）
- [ ] 是否要私有仓库（私有仓不能走 raw 镜像，只能用自建反代 + token）
