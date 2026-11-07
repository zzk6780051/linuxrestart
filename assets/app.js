(function () {
  "use strict";

  var cfg = window.LINUXRESTART_CONFIG || {};
  var isGitHubPages = /\.github\.io$/i.test(location.hostname);
  var base = ((isGitHubPages ? cfg.apiBaseOnGitHubPages : cfg.apiBase) || "").replace(/\/+$/, "");
  var apiUrl = base + "/api/state";
  var PASS_KEY = "linuxrestart.passcode";
  var REFRESH_MS = 60000;

  var els = {
    power: document.getElementById("power"),
    wrap: document.querySelector(".switch-wrap"),
    status: document.getElementById("status"),
    updated: document.getElementById("updated"),
    lastReboot: document.getElementById("lastReboot"),
    hint: document.getElementById("hint"),
    refresh: document.getElementById("refresh"),
    mode: document.getElementById("mode"),
    sync: document.getElementById("sync"),
    toast: document.getElementById("toast"),
    passModal: document.getElementById("passModal"),
    passForm: document.getElementById("passForm"),
    passInput: document.getElementById("passInput"),
    passCancel: document.getElementById("passCancel")
  };

  var state = null;
  var busy = false;
  var toastTimer = 0;
  var pendingPower = null;

  els.mode.textContent = isGitHubPages ? "GitHub Pages" : (base ? "自定义 API" : "Cloudflare Pages");

  function passcode() {
    try { return localStorage.getItem(PASS_KEY) || ""; } catch (e) { return ""; }
  }

  function setPasscode(v) {
    try {
      if (v) localStorage.setItem(PASS_KEY, v);
      else localStorage.removeItem(PASS_KEY);
    } catch (e) { /* 隐私模式下忽略 */ }
  }

  function toast(message, tone) {
    els.toast.textContent = message;
    els.toast.dataset.tone = tone || "";
    els.toast.hidden = false;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(function () { els.toast.hidden = true; }, tone === "error" ? 6000 : 3500);
  }

  function fmt(iso) {
    if (!iso) return "—";
    var d = new Date(iso);
    if (isNaN(d.getTime())) return String(iso);
    var pad = function (n) { return String(n).padStart(2, "0"); };
    return d.getFullYear() + "-" + pad(d.getMonth() + 1) + "-" + pad(d.getDate()) +
      " " + pad(d.getHours()) + ":" + pad(d.getMinutes()) + ":" + pad(d.getSeconds());
  }

  function setBusy(on) {
    busy = on;
    els.power.disabled = on;
    els.refresh.disabled = on;
    if (on) els.status.textContent = "正在提交…";
  }

  function render() {
    var on = !!(state && state.power);
    els.power.classList.toggle("is-on", on);
    els.wrap.classList.toggle("is-on", on);
    els.power.setAttribute("aria-pressed", on ? "true" : "false");
    els.status.dataset.tone = on ? "on" : "off";
    els.status.textContent = on ? "已开启 · 等待定时任务执行重启" : "已关闭";
    els.hint.textContent = on
      ? "定时任务每 2 小时检测一次；执行前会把状态写回「关闭」，因此重启后不会重复触发。"
      : "打开后由 NAS 上的定时任务在 2 小时内检测并执行重启，状态会写回 GitHub 仓库。";
    els.updated.textContent = fmt(state && state.updated_at);
    els.lastReboot.textContent = fmt(state && state.last_reboot_at);
    els.sync.textContent = "已同步 " + new Date().toLocaleTimeString("zh-CN", { hour12: false });
  }

  function renderError(message) {
    els.status.dataset.tone = "error";
    els.status.textContent = message;
    els.sync.textContent = "同步失败";
  }

  async function readState() {
    var res, data;
    try {
      res = await fetch(apiUrl, { cache: "no-store" });
    } catch (err) {
      renderError("网络不可达：无法连接 API");
      throw err;
    }
    try { data = await res.json(); } catch (e) { data = null; }
    if (!res.ok) {
      var msg = (data && data.message) || ("API 返回 HTTP " + res.status);
      if (res.status === 404 && isGitHubPages) {
        msg = "GitHub Pages 不支持服务端函数，请在 assets/config.js 配置 apiBaseOnGitHubPages";
      }
      renderError(msg);
      throw new Error(msg);
    }
    state = data;
    render();
    return state;
  }

  function openPassModal(power) {
    pendingPower = power;
    els.passInput.value = passcode();
    els.passModal.hidden = false;
    setTimeout(function () { els.passInput.focus(); }, 30);
  }

  function closePassModal() {
    els.passModal.hidden = true;
    pendingPower = null;
  }

  async function writePower(power) {
    var headers = { "content-type": "application/json" };
    var pwd = passcode();
    if (pwd) headers["x-passcode"] = pwd;

    var res = await fetch(apiUrl, {
      method: "POST",
      headers: headers,
      cache: "no-store",
      body: JSON.stringify({ power: power })
    });
    var data = null;
    try { data = await res.json(); } catch (e) { data = null; }

    if (res.status === 401) {
      setPasscode("");
      openPassModal(power);
      throw new Error("passcode_required");
    }
    if (!res.ok) {
      var msg = (data && data.message) || ("写入失败：HTTP " + res.status);
      throw new Error(msg);
    }
    state = data && data.state ? data.state : data;
    render();
    toast(power ? "已开启，将在 2 小时内重启" : "已取消重启计划", "ok");
  }

  async function toggle() {
    if (busy || !state) return;
    var next = !state.power;
    if (next) {
      var ok = window.confirm("确认要重启这台 Linux 吗？\n\n定时任务会在 2 小时内检测到开关并执行重启。");
      if (!ok) return;
    }
    setBusy(true);
    try {
      await writePower(next);
    } catch (err) {
      if (err && err.message !== "passcode_required") {
        toast(err.message || "操作失败", "error");
      }
      if (err && err.message === "passcode_required") {
        toast("请输入访问口令。", "error");
      }
    } finally {
      setBusy(false);
    }
  }

  els.power.addEventListener("click", toggle);
  els.refresh.addEventListener("click", function () {
    els.refresh.disabled = true;
    readState().catch(function () { /* 已展示错误 */ }).finally(function () {
      els.refresh.disabled = false;
    });
  });

  els.passForm.addEventListener("submit", function (ev) {
    ev.preventDefault();
    var value = els.passInput.value.trim();
    if (!value) return;
    setPasscode(value);
    var target = pendingPower;
    els.passModal.hidden = true;
    pendingPower = null;
    if (target === null) return;
    setBusy(true);
    writePower(target)
      .catch(function (err) {
        if (err && err.message !== "passcode_required") toast(err.message || "操作失败", "error");
        else toast("口令错误，请重试。", "error");
      })
      .finally(function () { setBusy(false); });
  });

  els.passCancel.addEventListener("click", closePassModal);
  els.passModal.addEventListener("click", function (ev) {
    if (ev.target === els.passModal) closePassModal();
  });
  document.addEventListener("keydown", function (ev) {
    if (ev.key === "Escape" && !els.passModal.hidden) closePassModal();
  });

  document.addEventListener("visibilitychange", function () {
    if (document.visibilityState === "visible") readState().catch(function () {});
  });

  readState().catch(function () {});
  setInterval(function () {
    if (!busy && document.visibilityState === "visible") readState().catch(function () {});
  }, REFRESH_MS);
})();
