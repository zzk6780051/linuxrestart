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
let putCalls = 0;
let conflictOnce = false;
let lastPutBody = null;

globalThis.fetch = async (url, init = {}) => {
  const method = (init.method || "GET").toUpperCase();
  const href = typeof url === "string" ? url : url.url;
  if (!href.startsWith("https://api.github.com/repos/o/r/contents/state.json")) {
    return new Response("unexpected url " + href, { status: 500 });
  }
  if (method === "GET") {
    if (state.missing) return new Response(JSON.stringify({ message: "Not Found" }), { status: 404 });
    return new Response(JSON.stringify({ sha: state.sha, content: b64(state.text) }), {
      status: 200,
      headers: { "content-type": "application/json" }
    });
  }
  if (method === "PUT") {
    putCalls += 1;
    const body = JSON.parse(init.body);
    lastPutBody = body;
    if (conflictOnce) {
      conflictOnce = false;
      return new Response(JSON.stringify({ message: "sha mismatch" }), { status: 409 });
    }
    if (body.sha !== state.sha) {
      return new Response(JSON.stringify({ message: "sha mismatch" }), { status: 409 });
    }
    state.text = unb64(body.content);
    state.sha = "sha-" + (putCalls + 1);
    return new Response(
      JSON.stringify({ content: { sha: state.sha }, commit: { sha: "c" + putCalls } }),
      { status: 200, headers: { "content-type": "application/json" } }
    );
  }
  return new Response("method not allowed", { status: 405 });
};

const env = { GITHUB_TOKEN: "test-token", GITHUB_REPO: "o/r", GITHUB_BRANCH: "main", TOGGLE_PASSCODE: "s3cret" };
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
