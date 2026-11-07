/**
 * Cloudflare Pages Function: /api/state
 *
 * 通过 GitHub Contents API 读写仓库里的 state.json。
 * GITHUB_TOKEN 只保存在 Cloudflare Pages 的环境变量（Secret）中，绝不下发到浏览器。
 *
 * 需要的环境变量：
 *   GITHUB_TOKEN      fine-grained PAT，权限 Contents: Read and write（必填）
 *   TOGGLE_PASSCODE   前端写操作口令（必填，否则写接口返回 503）
 *   GITHUB_REPO       默认 zzk6780051/linuxrestart
 *   GITHUB_BRANCH     默认 main
 *   STATE_PATH        默认 state.json
 *   ALLOWED_ORIGINS   CORS 白名单，默认 *
 *
 * 开关状态变化时，还会把「重启状态」写到 notify 仓库的通知里（可选，默认开启）：
 *   NOTIFY_ENABLED    默认 1；设 0 关闭
 *   NOTIFY_TOKEN      默认复用 GITHUB_TOKEN（需有 notify 仓库 Contents: Read and write）
 *   NOTIFY_REPO       默认 zzk6780051/notify
 *   NOTIFY_BRANCH     默认 main
 *   NOTIFY_PATH       默认 data.json
 *   NOTIFY_ID         默认 1（NAS 状态通知的 id）
 */

const API = "https://api.github.com";
// 用于确认 Cloudflare 部署版本是否生效（GET 响应里带 version 字段）
const FUNCTION_VERSION = "2-notify-toggle";

function cors(env) {
  return {
    "access-control-allow-origin": env.ALLOWED_ORIGINS || "*",
    "access-control-allow-methods": "GET,POST,OPTIONS",
    "access-control-allow-headers": "content-type,x-passcode",
    "access-control-max-age": "86400",
    vary: "Origin"
  };
}

function reply(env, body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
      ...cors(env)
    }
  });
}

function config(env) {
  const token = env.GITHUB_TOKEN;
  if (!token) return null;
  return {
    token,
    repo: env.GITHUB_REPO || "zzk6780051/linuxrestart",
    branch: env.GITHUB_BRANCH || "main",
    path: (env.STATE_PATH || "state.json").replace(/^\/+/, ""),
    passcode: env.TOGGLE_PASSCODE || ""
  };
}

function ghHeaders(cfg) {
  return {
    authorization: `Bearer ${cfg.token}`,
    accept: "application/vnd.github+json",
    "x-github-api-version": "2022-11-28",
    "user-agent": "linuxrestart-pages",
    "content-type": "application/json"
  };
}

function decodeBase64(b64) {
  const binary = atob(String(b64 || "").replace(/\s+/g, ""));
  const bytes = Uint8Array.from(binary, (c) => c.charCodeAt(0));
  return new TextDecoder().decode(bytes);
}

function encodeBase64(text) {
  const bytes = new TextEncoder().encode(text);
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

function normalize(raw, sha) {
  const src = raw && typeof raw === "object" ? raw : {};
  return {
    power: src.power === true,
    updated_at: typeof src.updated_at === "string" ? src.updated_at : null,
    updated_by: typeof src.updated_by === "string" ? src.updated_by : null,
    last_reboot_at: typeof src.last_reboot_at === "string" ? src.last_reboot_at : null,
    sha: sha || null
  };
}

async function ghGet(cfg) {
  const url = `${API}/repos/${cfg.repo}/contents/${encodeURIComponent(cfg.path)}?ref=${encodeURIComponent(cfg.branch)}`;
  const res = await fetch(url, { headers: ghHeaders(cfg), signal: AbortSignal.timeout(15000) });
  if (res.status === 404) return { missing: true, sha: null, data: null, status: 404 };
  if (!res.ok) {
    const detail = await res.text().catch(() => "");
    return { error: `GitHub GET ${res.status}`, detail: detail.slice(0, 500), status: 502 };
  }
  const data = await res.json();
  return { data, sha: data.sha, missing: false, status: 200 };
}

async function ghPut(cfg, content, sha, message) {
  const url = `${API}/repos/${cfg.repo}/contents/${encodeURIComponent(cfg.path)}`;
  const body = { message, content: encodeBase64(content), branch: cfg.branch };
  if (sha) body.sha = sha;
  return fetch(url, {
    method: "PUT",
    headers: ghHeaders(cfg),
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(15000)
  });
}

function readStatePayload(fetched) {
  if (fetched.missing) return {};
  const decoded = decodeBase64(fetched.data.content || "");
  if (!decoded.trim()) return {};
  try {
    const parsed = JSON.parse(decoded);
    return parsed && typeof parsed === "object" ? parsed : {};
  } catch (err) {
    throw new Error("state.json 不是合法 JSON: " + err.message);
  }
}

function notifyConfig(env) {
  if (String(env.NOTIFY_ENABLED ?? "1") === "0") return null;
  const token = env.NOTIFY_TOKEN || env.GITHUB_TOKEN;
  if (!token) return null;
  return {
    token,
    repo: env.NOTIFY_REPO || "zzk6780051/notify",
    branch: env.NOTIFY_BRANCH || "main",
    path: (env.NOTIFY_PATH || "data.json").replace(/^\/+/, ""),
    id: Number(env.NOTIFY_ID || 1)
  };
}

function beijingStamp() {
  return new Date(Date.now() + 8 * 3600 * 1000).toISOString().slice(0, 19);
}

const REBOOT_ON_TEXT =
  "🔄 网页开关已开启 · __TIME__<br><br>已把重启请求写入 state.json，等待 NAS 定时任务执行。<br>" +
  "🔄 重启计划: 已开启 — 约 1 小时内重启本机<br><br>如需取消，请在页面上关闭开关，本轮就不会重启。<br>" +
  "🤖 由网页开关自动上报";
const REBOOT_OFF_TEXT =
  "⏸️ 网页开关已关闭 · __TIME__<br><br>已取消重启计划，本轮不会重启。<br>" +
  "🔄 重启计划: 未开启 — 不会重启<br><br>🤖 由网页开关自动上报";

async function notifyUpsert(env, cfg, title, content) {
  const n = notifyConfig(env);
  if (!n) return { skipped: true };
  const ncfg = { ...cfg, token: n.token, repo: n.repo, branch: n.branch, path: n.path };
  for (let attempt = 0; attempt < 3; attempt += 1) {
    const fetched = await ghGet(ncfg);
    if (fetched.error) return { error: fetched.error };
    let raw = {};
    if (!fetched.missing) {
      try {
        raw = JSON.parse(decodeBase64(fetched.data.content || "")) || {};
      } catch (err) {
        return { error: "notify data.json 不是合法 JSON: " + err.message };
      }
    }
    const list = Array.isArray(raw.notifications) ? raw.notifications.slice() : [];
    const item = { id: n.id, title, content, date: beijingStamp() };
    const idx = list.findIndex((x) => x && Number(x.id) === n.id);
    if (idx >= 0) list[idx] = { ...list[idx], ...item };
    else list.push(item);
    const next = { ...raw, notifications: list };
    const res = await ghPut(ncfg, JSON.stringify(next, null, 2) + "\n", fetched.sha, `linuxrestart: ${title}`);
    if (res.ok) return { ok: true };
    if (res.status === 409 || res.status === 422) {
      await new Promise((r) => setTimeout(r, 200 * (attempt + 1)));
      continue;
    }
    const detail = await res.text().catch(() => "");
    return { error: `GitHub PUT ${res.status}`, detail: detail.slice(0, 300) };
  }
  return { error: "conflict" };
}

export async function onRequestGet({ env }) {
  const cfg = config(env);
  if (!cfg) {
    return reply(env, { error: "not_configured", message: "缺少 GITHUB_TOKEN 环境变量" }, 503);
  }
  try {
    const fetched = await ghGet(cfg);
    if (fetched.error) {
      return reply(env, { error: "github_error", message: fetched.error, detail: fetched.detail }, 502);
    }
    const raw = readStatePayload(fetched);
    const data = normalize(raw, fetched.sha);
    if (fetched.missing) data.missing = true;
    return reply(env, { ...data, version: FUNCTION_VERSION });
  } catch (err) {
    return reply(env, { error: "internal", message: err.message || String(err) }, 500);
  }
}

export async function onRequestPost({ request, env }) {
  const cfg = config(env);
  if (!cfg) {
    return reply(env, { error: "not_configured", message: "缺少 GITHUB_TOKEN 环境变量" }, 503);
  }
  if (!cfg.passcode) {
    return reply(
      env,
      { error: "not_configured", message: "服务端未配置 TOGGLE_PASSCODE，写操作已禁用" },
      503
    );
  }
  const provided = request.headers.get("x-passcode") || "";
  if (provided !== cfg.passcode) {
    return reply(env, { error: "passcode_required", message: "访问口令缺失或错误" }, 401);
  }

  let body;
  try {
    body = await request.json();
  } catch (err) {
    return reply(env, { error: "bad_request", message: "请求体不是合法 JSON" }, 400);
  }
  if (!body || typeof body.power !== "boolean") {
    return reply(env, { error: "bad_request", message: "字段 power 必须是布尔值" }, 400);
  }

  try {
    for (let attempt = 0; attempt < 3; attempt += 1) {
      const fetched = await ghGet(cfg);
      if (fetched.error) {
        return reply(env, { error: "github_error", message: fetched.error, detail: fetched.detail }, 502);
      }
      const raw = readStatePayload(fetched);
      const prevPower = raw.power === true;
      const now = new Date().toISOString();
      const next = {
        ...raw,
        power: body.power,
        updated_at: now,
        updated_by: "web"
      };
      const res = await ghPut(
        cfg,
        JSON.stringify(next, null, 2) + "\n",
        fetched.sha,
        body.power ? "linuxrestart: switch ON (queued)" : "linuxrestart: switch OFF"
      );
      if (res.ok) {
        const saved = await res.json();
        let notify = "skipped";
        if (body.power !== prevPower) {
          try {
            const stamp = beijingStamp();
            const result = body.power
              ? await notifyUpsert(env, cfg, "🔄 重启开关已开启", REBOOT_ON_TEXT.replace("__TIME__", stamp))
              : await notifyUpsert(env, cfg, "⏸️ 重启开关已关闭", REBOOT_OFF_TEXT.replace("__TIME__", stamp));
            notify = result.ok ? "ok" : result.skipped ? "skipped" : "failed";
          } catch (err) {
            notify = "failed";
          }
        }
        return reply(env, { ok: true, state: normalize(next, saved?.content?.sha), notify });
      }
      if (res.status === 409 || res.status === 422) {
        await new Promise((r) => setTimeout(r, 200 * (attempt + 1)));
        continue;
      }
      const detail = await res.text().catch(() => "");
      return reply(
        env,
        { error: "github_error", message: `GitHub PUT ${res.status}`, detail: detail.slice(0, 500) },
        502
      );
    }
    return reply(env, { error: "conflict", message: "写入冲突，请稍后重试" }, 409);
  } catch (err) {
    return reply(env, { error: "internal", message: err.message || String(err) }, 500);
  }
}

export async function onRequestOptions({ env }) {
  return new Response(null, { status: 204, headers: cors(env) });
}

export async function onRequest({ request, env }) {
  if (request.method === "GET") return onRequestGet({ request, env });
  if (request.method === "POST") return onRequestPost({ request, env });
  if (request.method === "OPTIONS") return onRequestOptions({ request, env });
  return reply(env, { error: "method_not_allowed" }, 405);
}
