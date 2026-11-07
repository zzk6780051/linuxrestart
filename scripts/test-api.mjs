#!/usr/bin/env node
/**
 * 本地测试 Cloudflare Pages Function（functions/api/state.js）的逻辑。
 * 用内存 mock 替换 GitHub API，不访问网络、不需要 token。
 *
 * 运行： node scripts/test-api.mjs
 */
import fs from "node:fs";
import assert from "node:assert/strict";

const source = fs.readFileSync(new URL("../functions/api/state.js", import.meta.url), "utf8");
const transformed = source.replace(/export async function/g, "async function");
const fn = new Function(
  transformed + "\nreturn { onRequestGet, onRequestPost, onRequestOptions, onRequest };"
)();

const b64 = (s) => Buffer.from(s, "utf8").toString("base64");
const unb64 = (s) => Buffer.from(String(s).replace(/\s+/g, ""), "base64").toString("utf8");

const state = { sha: "sha-1", text: JSON.stringify({ power: false, updated_at: "2026-01-01T00:00:00Z" }) };
const notify = {
  sha: "nsha-1",
  text: JSON.stringify({
    notifications: [{ id: 1, title: "🟢 NAS 在线正常", content: "old", date: "2026-01-01T00:00:00" }]
  })
};
let putCalls = 0;
let notifyPutCalls = 0;
let conflictOnce = false;
let notifyFail = false;
let lastPutBody = null;

function route(href) {
  if (href.startsWith("https://api.github.com/repos/o/r/contents/state.json")) return state;
  if (href.startsWith("https://api.github.com/repos/zzk6780051/notify/contents/data.json")) return notify;
  return null;
}

globalThis.fetch = async (url, init = {}) => {
  const method = (init.method || "GET").toUpperCase();
  const href = typeof url === "string" ? url : url.url;
  const store = route(href);
  if (!store) {
    return new Response("unexpected url " + href, { status: 500 });
  }
  const isNotify = store === notify;
  if (method === "GET") {
    if (store.missing) return new Response(JSON.stringify({ message: "Not Found" }), { status: 404 });
    return new Response(JSON.stringify({ sha: store.sha, content: b64(store.text) }), {
      status: 200,
      headers: { "content-type": "application/json" }
    });
  }
  if (method === "PUT") {
    if (isNotify) {
      if (notifyFail) return new Response(JSON.stringify({ message: "boom" }), { status: 500 });
      notifyPutCalls += 1;
    } else {
      putCalls += 1;
      lastPutBody = JSON.parse(init.body);
    }
    const body = JSON.parse(init.body);
    if (conflictOnce && !isNotify) {
      conflictOnce = false;
      return new Response(JSON.stringify({ message: "sha mismatch" }), { status: 409 });
    }
    if (body.sha !== store.sha) {
      return new Response(JSON.stringify({ message: "sha mismatch" }), { status: 409 });
    }
    store.text = unb64(body.content);
    store.sha = (isNotify ? "nsha-" : "sha-") + (isNotify ? notifyPutCalls : putCalls);
    return new Response(
      JSON.stringify({ content: { sha: store.sha }, commit: { sha: "c" + (isNotify ? notifyPutCalls : putCalls) } }),
      { status: 200, headers: { "content-type": "application/json" } }
    );
  }
  return new Response("method not allowed", { status: 405 });
};

const env = {
  GITHUB_TOKEN: "test-token",
  GITHUB_REPO: "o/r",
  GITHUB_BRANCH: "main",
  TOGGLE_PASSCODE: "s3cret",
  NOTIFY_REPO: "zzk6780051/notify",
  NOTIFY_BRANCH: "main",
  NOTIFY_PATH: "data.json",
  NOTIFY_ID: "1"
};
const notifyItem = () => JSON.parse(notify.text).notifications.find((n) => n.id === 1);
const req = (method, headers = {}, body) =>
  new Request("https://example.test/api/state", {
    method,
    headers,
    body: body ? JSON.stringify(body) : undefined
  });

let passed = 0;
async function test(name, run) {
  await run();
  passed += 1;
  console.log("  ok -", name);
}

await test("GET 读取现有状态", async () => {
  const res = await fn.onRequestGet({ request: req("GET"), env });
  assert.equal(res.status, 200);
  const data = await res.json();
  assert.equal(data.power, false);
  assert.equal(data.sha, "sha-1");
  assert.equal(data.version, "2-notify-toggle");
});

await test("GET 状态文件不存在时按关闭处理", async () => {
  state.missing = true;
  const res = await fn.onRequestGet({ request: req("GET"), env });
  state.missing = false;
  const data = await res.json();
  assert.equal(res.status, 200);
  assert.equal(data.power, false);
  assert.equal(data.missing, true);
});

await test("POST 缺少 passcode 配置时返回 503", async () => {
  const res = await fn.onRequestPost({
    request: req("POST", { "content-type": "application/json" }, { power: true }),
    env: { ...env, TOGGLE_PASSCODE: "" }
  });
  assert.equal(res.status, 503);
});

await test("POST 口令错误返回 401", async () => {
  const res = await fn.onRequestPost({
    request: req("POST", { "content-type": "application/json", "x-passcode": "nope" }, { power: true }),
    env
  });
  assert.equal(res.status, 401);
});

await test("POST 非布尔 power 返回 400", async () => {
  const res = await fn.onRequestPost({
    request: req("POST", { "content-type": "application/json", "x-passcode": "s3cret" }, { power: "yes" }),
    env
  });
  assert.equal(res.status, 400);
});

await test("POST 打开开关并写入 GitHub", async () => {
  const res = await fn.onRequestPost({
    request: req("POST", { "content-type": "application/json", "x-passcode": "s3cret" }, { power: true }),
    env
  });
  assert.equal(res.status, 200);
  const data = await res.json();
  assert.equal(data.ok, true);
  assert.equal(data.state.power, true);
  assert.equal(lastPutBody.branch, "main");
  const saved = JSON.parse(unb64(lastPutBody.content));
  assert.equal(saved.power, true);
  assert.equal(saved.updated_by, "web");
});

await test("POST 遇到 409 冲突后重试成功", async () => {
  conflictOnce = true;
  const res = await fn.onRequestPost({
    request: req("POST", { "content-type": "application/json", "x-passcode": "s3cret" }, { power: false }),
    env
  });
  const data = await res.json();
  assert.equal(res.status, 200);
  assert.equal(data.state.power, false);
});

await test("POST 打开开关时写入 notify 重启状态", async () => {
  const before = notifyPutCalls;
  const res = await fn.onRequestPost({
    request: req("POST", { "content-type": "application/json", "x-passcode": "s3cret" }, { power: true }),
    env
  });
  const data = await res.json();
  assert.equal(res.status, 200);
  assert.equal(data.notify, "ok");
  assert.equal(notifyPutCalls, before + 1);
  const item = notifyItem();
  assert.match(item.title, /重启开关已开启/);
  assert.match(item.content, /重启计划: 已开启/);
  assert.match(item.date, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$/);
});

await test("重复打开（状态未变化）不重复写 notify", async () => {
  const before = notifyPutCalls;
  const res = await fn.onRequestPost({
    request: req("POST", { "content-type": "application/json", "x-passcode": "s3cret" }, { power: true }),
    env
  });
  const data = await res.json();
  assert.equal(res.status, 200);
  assert.equal(data.notify, "skipped");
  assert.equal(notifyPutCalls, before);
});

await test("POST 关闭开关时写入 notify 取消状态", async () => {
  const before = notifyPutCalls;
  const res = await fn.onRequestPost({
    request: req("POST", { "content-type": "application/json", "x-passcode": "s3cret" }, { power: false }),
    env
  });
  const data = await res.json();
  assert.equal(res.status, 200);
  assert.equal(data.notify, "ok");
  assert.equal(notifyPutCalls, before + 1);
  const item = notifyItem();
  assert.match(item.title, /重启开关已关闭/);
  assert.match(item.content, /重启计划: 未开启/);
});

await test("notify 写入失败不影响开关状态写入", async () => {
  notifyFail = true;
  const res = await fn.onRequestPost({
    request: req("POST", { "content-type": "application/json", "x-passcode": "s3cret" }, { power: true }),
    env
  });
  notifyFail = false;
  const data = await res.json();
  assert.equal(res.status, 200);
  assert.equal(data.ok, true);
  assert.equal(data.notify, "failed");
  assert.equal(data.state.power, true);
});

await test("NOTIFY_ENABLED=0 时不写 notify", async () => {
  const before = notifyPutCalls;
  const res = await fn.onRequestPost({
    request: req("POST", { "content-type": "application/json", "x-passcode": "s3cret" }, { power: false }),
    env: { ...env, NOTIFY_ENABLED: "0" }
  });
  const data = await res.json();
  assert.equal(data.notify, "skipped");
  assert.equal(notifyPutCalls, before);
});

await test("OPTIONS 返回 CORS 预检", async () => {
  const res = await fn.onRequestOptions({ request: req("OPTIONS"), env });
  assert.equal(res.status, 204);
  assert.equal(res.headers.get("access-control-allow-origin"), "*");
});

await test("未配置 GITHUB_TOKEN 时 GET 返回 503", async () => {
  const res = await fn.onRequestGet({ request: req("GET"), env: { ...env, GITHUB_TOKEN: "" } });
  assert.equal(res.status, 503);
});

console.log(`\n全部通过：${passed} 项`);
