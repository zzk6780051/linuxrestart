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
 */

const API = "https://api.github.com";

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
    return reply(env, data);
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
        return reply(env, { ok: true, state: normalize(next, saved?.content?.sha) });
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
