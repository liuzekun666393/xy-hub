# agent-side.md — AI 侧：拿到配对串之后怎么装

> 客户把 `xy1://HOST/KEY` 发来，你就有了这台机器的命令执行权。
> **只做安装调试，不做别的**（边界见 installer.md §7）。

## 1. 拆配对串

```
xy1://<HOST>/<KEY>      →  BASE=https://<HOST>   KEY=<KEY>
xy0://127.0.0.1:<PORT>/<KEY>  → 本地调试（客户同机）
```

环境变量（本次会话内用，**不写进用户 md、不写进日志**）：

```bash
BASE="https://<HOST>"; KEY="<KEY>"
xy() { curl -sS -H "X-Key: $KEY" -H 'content-type: application/json' "$@"; }
```

## 2. 五个动作（全部 curl，无需额外客户端）

```bash
# 1) 心跳 / 确认还活着
xy "$BASE/ping"

# 2) 执行命令（默认 120s，最长 900s）
xy -X POST "$BASE/exec" -d '{"cmd":"whoami && ver","timeout":60}'

# 3) 列目录（只看安装区，别乱翻）
xy "$BASE/ls?path=."

# 4) 取文件（日志/截图文本）
xy "$BASE/get?path=logs/app.log" -o /tmp/app.log

# 5) 传文件（base64，≤2MB；大文件让客户自己下）
B64=$(base64 -w0 setup.cfg)
xy -X POST "$BASE/put" -d "{\"path\":\"XY_ROOT/setup.cfg\",\"b64\":\"$B64\"}"

# 收工
xy -X POST "$BASE/shutdown"
```

Windows 客户机（`cmd.exe` 语义）：

```bash
xy -X POST "$BASE/exec" -d '{"cmd":"powershell -NoProfile -Command \"Get-CimInstance Win32_OperatingSystem | Select Caption,Version\"","timeout":60}'
```

## 3. 标准安装序列（照 installer.md 走）

```
1. 侦察：OS/版本/架构/磁盘/已装 python/node/git/显卡   → 写 users/<cid>.md
2. 建目录：D:\XY\<pkg>（Linux /opt/xy/<pkg>）
3. 装依赖：能 winget/apt 就包管理器，装不了才手工解压（文件走 /put）
4. 写配置：/put 落 json/ini；密钥用占位 → 让客户自己填或本机生成
5. 自启：schtasks / systemd unit（命令确认返回 0）
6. 冒烟：跑最小命令，看 stdout（不是"应该可以"）
7. 验收：按 delivery_checklist.md 逐条跑，把输出贴进用户 md
8. 清理：/shutdown + 提醒客户删 xy_boot
```

## 4. 判失败的硬信号

| 信号 | 含义 | 动作 |
| --- | --- | --- |
| `403 bad key` | key 错/过期 | 让客户重跑，别重试超过 2 次 |
| `403 expired` | TTL 到 | 同上 |
| `timeout` | 命令卡住 | 换更短命令先确认环境（如只跑 `where python`） |
| `path outside root` | 想访问 root 外 | **停**：这说明在越界，改回安装目录 |
| 隧道 502/1033 | cloudflared 挂了 | 客户重跑脚本 |
| 空 stdout + code 0 | 命令没输出 | 用 `echo done` 之类确认 shell 真的执行了 |

## 5. 安全与礼貌

- 每一步都告诉客户"我现在在做什么"（一句话），不要闷头跑十条命令。
- 不读客户隐私目录（相册/文档/浏览器数据），需要看日志就只看 `XY_ROOT/logs`。
- 不装常驻远控、不留免密入口、不在客户机保存我的 key。
- 客户中途说"停" → 立刻停手，`/shutdown`，说明已做到哪一步。
- 结束后 24h 内不主动再连；要复访先让客户重跑脚本拿新 key。
