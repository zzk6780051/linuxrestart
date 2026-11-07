/**
 * 运行配置
 *
 * apiBase: 前端调用 /api/state 的基址。
 * 页面和 Functions 同源部署在 Cloudflare Pages 上，留空即可（请求当前域名下的 /api/state）。
 * 仅当你把静态文件放到别的域名（例如另一个静态托管）时，才改成 Cloudflare Pages 的地址，
 * 例如 "https://linuxrestart.pages.dev"，并在 Cloudflare 侧配置 ALLOWED_ORIGINS 允许跨域。
 */
window.LINUXRESTART_CONFIG = {
  apiBase: ""
};
