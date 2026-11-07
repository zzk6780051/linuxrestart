/*
 * 前端配置（公开信息，绝不能放 token）。
 *
 * apiBase: 同源部署（Cloudflare Pages）时留空，页面请求 /api/state。
 *          GitHub Pages 无法运行服务端函数，必须指向 Cloudflare 的地址。
 * apiBaseOnGitHubPages: 仅当页面通过 *.github.io 打开时使用。
 */
window.LINUXRESTART_CONFIG = {
  apiBase: "",
  apiBaseOnGitHubPages: "" // 例如 "https://linuxrestart.pages.dev"
};
