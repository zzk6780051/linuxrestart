# Linux Restart

一个「远程重启开关」：网页上只有一个按钮，开关状态写入 GitHub 仓库里的 `state.json`；
NAS 上的定时任务**每小时**检查一次，若为开启状态则**先把状态写回关闭，再重启本机**。
同一个定时任务还会每小时检查一次 NAS 状态，并写入 [notify 仓库](https://github.com/zzk6780051/notify)
`data.json` 的 `id=1` 通知（「实时通知中心」页面展示）。

```
       浏览器（Cloudflare Pages）
                    │  点击开关
                    ▼
   Cloudflare Pages Functions  /api/state  ← GITHUB_TOKEN（环境密钥，不下发浏览器）
                    │  GitHub Contents API
                    ▼
        GitHub 仓库 state.json  {"power": true}
                    │
                    ▼
   NAS cron（每小时） linuxrestart-guard
                    │  ① NAS 状态检查（负载/内存/磁盘/温度/端口）
                    │     └→ notify 仓库 data.json（id=1 通知）
                    │  ② power=true → 写回 false → 校验 → reboot
                    ▼
                Linux 重启
```

- **先写回再重启**：即使重启中途失败也不会出现「开机即再次重启」的循环。
- **token 只在服务端**：浏览器只访问 `/api/state`，拿不到任何凭据。
- **写操作有口令**：`TOGGLE_PASSCODE` 未配置时写接口直接 503。
- **单一部署**：页面与 API 全部由 Cloudflare Pages 提供（Git 集成部署），不用 GitHub Pages。
- **每小时上报**：NAS 存活状态会写进 notify 页面（id=1 通知），同时避免其监控工作流误判「NAS 离线」。

## 目录

| 路径 | 作用 |
| --- | --- |
| `index.html` / `assets/` | 开关页面（纯静态） |
| `functions/api/state.js` | Cloudflare Pages Function：读写 GitHub 状态文件 |
| `state.json` | 开关状态（由页面/守护脚本提交更新） |
| `scripts/linuxrestart-guard.sh` | NAS 端守护脚本（cron 每小时执行，含 NAS 状态上报） |
| `scripts/install.sh` | 安装脚本（写 cron、日志、配置模板） |
| `scripts/test-api.mjs` | API 逻辑单测（mock GitHub） |
| `scripts/test-guard.sh` | 守护脚本 dry-run 测试（mock GitHub） |
| `_routes.json` / `_headers` | Cloudflare Pages 路由与响应头配置 |

## 一、准备 GitHub Token

用 **Fine-grained token**（不要用 classic PAT，权限太大）：

GitHub → Settings → Developer settings → **Fine-grained tokens** → Generate new token：

- Repository access：仅选择 `zzk6780051/linuxrestart`
- Permissions：**Contents → Read and write**
- 生成后复制 `github_pat_...`（只显示一次）

## 二、部署 Cloudflare Pages（同时提供页面与 API）

1. Cloudflare Dashboard → Workers & Pages → **Create → Pages → Connect to Git**，授权并选择本仓库
   （`zzk6780051/linuxrestart`，分支 `main`）。
2. 构建设置：
   - Framework preset：`None`
   - Build command：`rm -rf dist && mkdir -p dist && cp -r index.html _headers _routes.json assets dist`
   - Build output directory：`dist`
   - 其余默认即可。
3. **Environment variables**（Production 和 Preview 都加，`GITHUB_TOKEN` / `TOGGLE_PASSCODE` 用 Secret 类型）：

   | 变量 | 值 |
   | --- | --- |
   | `GITHUB_TOKEN` | 第一步的 fine-grained PAT |
   | `TOGGLE_PASSCODE` | 自定义访问口令，例如一串随机字符 |
   | `GITHUB_REPO` | `zzk6780051/linuxrestart` |
   | `GITHUB_BRANCH` | `main` |
   | `STATE_PATH` | `state.json` |
   | `ALLOWED_ORIGINS` | 可选，默认 `*`；若前端不在同源域名部署再收窄 |

4. 保存并部署，得到 `https://<project>.pages.dev`。打开后点开关，能读取并写入状态即成功。
   因为页面与 `/api` 同源，`assets/config.js` 不需要任何修改。

> 注意：Cloudflare Pages 的 Functions 只在 **Git 集成部署** 时生效，Direct Upload 无效。
> `_routes.json` 已把 Functions 限制在 `/api/*`，静态资源走 CDN。
>
> 仓库里已关闭 GitHub Pages（无 `pages.yml` 工作流）；静态页面只通过 Cloudflare 访问。

## 三、配置 NAS 定时任务

在 NAS 上（仓库目录内）：

```sh
sudo bash scripts/install.sh
```

会安装（每小时整点执行，重启检查 + NAS 状态上报；另加一条 `@reboot`，每次开机后自动上报一次 NAS 状态）：

- `/usr/local/sbin/linuxrestart-guard`
- `/etc/linuxrestart/linuxrestart.env`（权限 600，仅 root 可读）
- `/etc/cron.d/linuxrestart`：`0 * * * * root /usr/local/sbin/linuxrestart-guard`（每小时整点）
- `/var/log/linuxrestart.log` + logrotate

然后填入 token（与 Cloudflare 里的可以用同一个）：

```sh
sudo vi /etc/linuxrestart/linuxrestart.env
# GITHUB_TOKEN=github_pat_xxx
```

联调（**建议先把 DRY_RUN 保持 1**）：

```sh
sudo /usr/local/sbin/linuxrestart-guard --status     # 查看开关 + NAS 状态
sudo /usr/local/sbin/linuxrestart-guard --check      # 只做 NAS 检查并上报 notify
sudo /usr/local/sbin/linuxrestart-guard --dry-run    # 只写回状态，不重启、不上报
# 确认无误后把 DRY_RUN 改为 0
```

### NAS 状态上报配置（`/etc/linuxrestart/linuxrestart.env`）

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `NOTIFY_ENABLED` | `1` | 是否每轮把 NAS 状态写进 notify 仓库 |
| `NOTIFY_REPO` | `zzk6780051/notify` | 通知仓库 |
| `NOTIFY_PATH` / `NOTIFY_BRANCH` | `data.json` / `main` | 通知文件与分支 |
| `NOTIFY_ID` | `1` | 复用的通知条目 id（页面和监控工作流都读这条） |
| `NOTIFY_TOKEN` | 回退到 `GITHUB_TOKEN` | 需要能写 notify 仓库 |
| `NAS_NAME` | `hostname` | 通知里显示的机器名 |
| `CHECK_MOUNTS` | `/,/vol1` | 要检查的磁盘挂载点 |
| `DISK_WARN_PCT` | `90` | 磁盘占用超过该值判为异常 |
| `MEM_WARN_PCT` | `95` | 内存占用超过该值判为异常 |
| `CHECK_PORTS` | `22:SSH,2298:DSH,5667:fnOS` | 要检查的端口（端口:名称） |

上报内容：运行时长、1/5/15 分钟负载、内存占用、各磁盘占用、CPU 温度、各端口连通性，
以及**是否将会重启**（`⏸️ 重启计划: 未开启 — 不会重启` / `🔄 重启计划: 已开启 — 本机将在本轮检查中重启`
/ `❔ 重启计划: 未知`）和下次检查时间；
有任何端口不可达或磁盘/内存超阈值时，标题变为「🔴 NAS 状态异常」并列出异常项。

另外，网页开关被打开/关闭的**那一刻**，Cloudflare Pages Function 也会立即把重启状态写进同一条通知
（「🔄 重启开关已开启 … 约 1 小时内重启」/「⏸️ 重启开关已关闭 …」），不用等下一次整点检查；
NAS 重启完成开机后，`@reboot` 的 `--boot` 会先等网络就绪、再等关键端口（`CHECK_PORTS`）就绪
（最长 `BOOT_MAX_WAIT=300` 秒），然后自动跑一次检查，尽快把页面刷新成「🟢 NAS 在线正常」；
不会因为服务还没启动就误报「🔴 NAS 状态异常」。
Function 里相关环境变量（都有默认值，通常不必配）：`NOTIFY_ENABLED`、`NOTIFY_TOKEN`、`NOTIFY_REPO`、
`NOTIFY_BRANCH`、`NOTIFY_PATH`、`NOTIFY_ID`。
触发重启时会先上报「🔄 NAS 即将重启」，重启后下一轮再报「🟢 NAS 在线正常」。

真实测试：网页打开开关 → 等下一次整点（或手动执行一次守护脚本）→ 机器重启，
`state.json` 变为 `false` 且 `last_reboot_at` 有值。

## 四、使用

- **打开开关**：确认弹窗后写入 `power: true`，最多 1 小时内重启；
  页面上会显示「已开启 · 等待定时任务执行重启」。
- **取消**：在定时任务执行前再点一次，写回 `power: false`。
- 页面每 60 秒自动刷新状态；也可点「刷新状态」。

## 五、安全提示

- `GITHUB_TOKEN` 只存在于 Cloudflare 环境变量和 NAS 的 root-only 文件里，仓库和前端都没有。
- `state.json` 是公开的（仓库 public），但状态本身不敏感。
- 写接口必须带 `x-passcode`；口令只存在浏览器 localStorage 和 Cloudflare 环境变量。
- 任何人都能读取状态（GET 不鉴权）；不希望公开展示可把仓库改为 private（Pages 仍可构建），
  或加 Cloudflare Access。
- token 一旦泄露（例如贴进聊天记录）应立即在 GitHub 吊销并重新生成。
- 若把 token 换成 fine-grained PAT，需要同时勾选 `linuxrestart` 和 `notify` 两个仓库的
  `Contents: Read and write`（或单独给 `NOTIFY_TOKEN` 配一个只有 notify 权限的 token）。

## 六、排错

| 现象 | 原因/处理 |
| --- | --- |
| 页面提示 `not_configured` | Cloudflare 缺 `GITHUB_TOKEN` 或 `TOGGLE_PASSCODE`，补环境变量后重新部署 |
| 输入口令仍 401 | 口令与 `TOGGLE_PASSCODE` 不一致；清掉 localStorage 后重试 |
| 页面 404 `/api/state` | 部署方式不是 Git 集成的 Pages，或 `dist` 里缺 `_routes.json` |
| 提示 `GitHub PUT 409` | 并发写冲突，页面会自动重试 3 次；仍失败可刷新后重试 |
| cron 没执行 | `systemctl status cron`；看 `/var/log/linuxrestart.log` |
| notify 页面没更新 | `grep '已上报 NAS 状态' /var/log/linuxrestart.log`；检查 `NOTIFY_*` 配置和 token 是否有 notify 仓库写权限 |
| 通知内容一直不变 | 确认 `NOTIFY_ENABLED=1` 且 `NOTIFY_ID` 与实际条目 id 一致 |
| 日志 `GITHUB_TOKEN 未配置` | 编辑 `/etc/linuxrestart/linuxrestart.env` |
| 重启没有发生 | 检查 `DRY_RUN` 是否为 0；`REBOOT_CMD` 是否存在；是否有 power 权限（root） |

## 七、本地测试

```sh
node scripts/test-api.mjs      # API 逻辑（mock GitHub，9 项）
bash scripts/test-guard.sh     # 守护脚本 + NAS 上报（mock GitHub，20 项）
```

## 八、卸载

```sh
sudo rm -f /etc/cron.d/linuxrestart /usr/local/sbin/linuxrestart-guard \
           /etc/logrotate.d/linuxrestart
sudo rm -rf /etc/linuxrestart
```

## License

见 [LICENSE](./LICENSE)。
