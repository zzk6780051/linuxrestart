# Linux Restart

一个「远程重启开关」：网页上只有一个按钮，开关状态写入 GitHub 仓库里的 `state.json`；
NAS 上的定时任务每 2 小时检查一次，若为开启状态则**先把状态写回关闭，再重启本机**。

```
       浏览器（GitHub Pages / Cloudflare Pages）
                    │  点击开关
                    ▼
   Cloudflare Pages Functions  /api/state  ← GITHUB_TOKEN（环境密钥，不下发浏览器）
                    │  GitHub Contents API
                    ▼
        GitHub 仓库 state.json  {"power": true}
                    │
                    ▼
   NAS cron（每 2 小时） linuxrestart-guard
                    │  power=true → 写回 false → 校验 → reboot
                    ▼
                Linux 重启
```

- **先写回再重启**：即使重启中途失败也不会出现「开机即再次重启」的循环。
- **token 只在服务端**：浏览器只访问 `/api/state`，拿不到任何凭据。
- **写操作有口令**：`TOGGLE_PASSCODE` 未配置时写接口直接 503。

## 目录

| 路径 | 作用 |
| --- | --- |
| `index.html` / `assets/` | 开关页面（纯静态） |
| `functions/api/state.js` | Cloudflare Pages Function：读写 GitHub 状态文件 |
| `state.json` | 开关状态（由页面/守护脚本提交更新） |
| `scripts/linuxrestart-guard.sh` | NAS 端守护脚本（cron 每 2 小时执行） |
| `scripts/install.sh` | 安装脚本（写 cron、日志、配置模板） |
| `scripts/test-api.mjs` | API 逻辑单测（mock GitHub） |
| `scripts/test-guard.sh` | 守护脚本 dry-run 测试（mock GitHub） |
| `.github/workflows/pages.yml` | GitHub Pages 自动部署 |

## 一、准备 GitHub Token

GitHub → Settings → Developer settings → **Fine-grained tokens** → Generate new token：

- Repository access：仅选择 `zzk6780051/linuxrestart`
- Permissions：**Contents → Read and write**
- 生成后复制 `github_pat_...`（只显示一次）

## 二、部署 Cloudflare Pages（提供 API）

1. Cloudflare Dashboard → Workers & Pages → Create → **Pages → Connect to Git**，选择本仓库。
2. 构建设置：
   - Framework preset：`None`
   - Build command：`mkdir -p dist && cp index.html _headers _routes.json state.json dist && cp -r assets dist`
   - Build output directory：`dist`
3. **Environment variables**（Production 和 Preview 都加）：

   | 变量 | 值 |
   | --- | --- |
   | `GITHUB_TOKEN` | 第一步的 PAT（建议用 Secret 类型） |
   | `TOGGLE_PASSCODE` | 自定义访问口令，例如一串随机字符 |
   | `GITHUB_REPO` | `zzk6780051/linuxrestart` |
   | `GITHUB_BRANCH` | `main` |
   | `STATE_PATH` | `state.json` |

4. 保存并部署，得到 `https://<project>.pages.dev`。
   浏览器打开后点开关，若能读取并写入状态即成功。

> 注意：Cloudflare Pages 的 Functions 只在 **Git 集成部署** 时生效，Direct Upload 不行。
> `_routes.json` 已把 Functions 限制在 `/api/*`，静态资源走 CDN。

## 三、启用 GitHub Pages（静态页面）

1. 仓库 Settings → Pages → **Source: GitHub Actions**。
2. 推送到 `main` 会自动运行 `.github/workflows/pages.yml`，页面地址：
   `https://zzk6780051.github.io/linuxrestart/`
3. GitHub Pages 只能托管静态文件，无法运行 `/api`，因此把 API 指向 Cloudflare：

   编辑 `assets/config.js`：

   ```js
   window.LINUXRESTART_CONFIG = {
     apiBase: "",
     apiBaseOnGitHubPages: "https://<project>.pages.dev"
   };
   ```

   提交后重新部署。Cloudflare 侧已允许跨域（`ALLOWED_ORIGINS` 默认 `*`；
   如需收紧，把它设为 `https://zzk6780051.github.io`）。

## 四、配置 NAS 定时任务

在 NAS 上（仓库目录内）：

```sh
sudo bash scripts/install.sh
```

会安装：

- `/usr/local/sbin/linuxrestart-guard`
- `/etc/linuxrestart/linuxrestart.env`（权限 600，仅 root 可读）
- `/etc/cron.d/linuxrestart`：`0 */2 * * * root /usr/local/sbin/linuxrestart-guard`
- `/var/log/linuxrestart.log` + logrotate

然后填入 token：

```sh
sudo vi /etc/linuxrestart/linuxrestart.env
# GITHUB_TOKEN=github_pat_xxx
```

联调（**建议先把 DRY_RUN 保持 1**）：

```sh
sudo /usr/local/sbin/linuxrestart-guard --status     # 查看当前状态
sudo /usr/local/sbin/linuxrestart-guard --dry-run    # 只写回状态，不重启
# 确认无误后把 DRY_RUN 改为 0
```

真实测试：网页打开开关 → 等下一次整点（或手动执行一次守护脚本）→ 机器重启，
`state.json` 变为 `false` 且 `last_reboot_at` 有值。

## 五、使用

- **打开开关**：确认弹窗后写入 `power: true`，最多 2 小时内重启；
  页面上会显示「已开启 · 等待定时任务执行重启」。
- **取消**：在定时任务执行前再点一次，写回 `power: false`。
- 页面每 60 秒自动刷新状态；也可点「刷新状态」。

## 六、安全提示

- `GITHUB_TOKEN` 只存在于 Cloudflare 环境变量和 NAS 的 root-only 文件里，仓库和前端都没有。
- `state.json` 是公开的（仓库 public），但状态本身不敏感。
- 写接口必须带 `x-passcode`；口令只存在浏览器 localStorage 和 Cloudflare 环境变量。
- 页面部署在公网，任何人都能读取状态（GET 不鉴权）；如果不希望公开展示，
  可以把仓库改为 private（Pages 仍可构建），或加 Cloudflare Access。
- `ALLOWED_ORIGINS` 可收窄到自己的域名。

## 七、排错

| 现象 | 原因/处理 |
| --- | --- |
| 页面提示 `not_configured` | Cloudflare 缺 `GITHUB_TOKEN` 或 `TOGGLE_PASSCODE`，补环境变量后重新部署 |
| 输入口令仍 401 | 口令与 `TOGGLE_PASSCODE` 不一致；清掉 localStorage 后重试 |
| 提示 `GitHub PUT 409` | 并发写冲突，页面会自动重试 3 次；仍失败可刷新后重试 |
| GitHub Pages 打开报错 404 API | 未配置 `apiBaseOnGitHubPages`，见第三步 |
| cron 没执行 | `systemctl status cron`；看 `/var/log/linuxrestart.log` |
| 日志 `GITHUB_TOKEN 未配置` | 编辑 `/etc/linuxrestart/linuxrestart.env` |
| 重启没有发生 | 检查 `DRY_RUN` 是否为 0；`REBOOT_CMD` 是否存在；是否有 power 权限（root） |

## 八、本地测试

```sh
node scripts/test-api.mjs      # API 逻辑（mock GitHub，9 项）
bash scripts/test-guard.sh     # 守护脚本 dry-run（mock GitHub，7 项）
```

## 九、卸载

```sh
sudo rm -f /etc/cron.d/linuxrestart /usr/local/sbin/linuxrestart-guard \
           /etc/logrotate.d/linuxrestart
sudo rm -rf /etc/linuxrestart
```

## License

见 [LICENSE](./LICENSE)。
