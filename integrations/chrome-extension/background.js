// Wisp Chrome extension - service worker.
//
// Bridges the Wisp daemon (wispd) to this browser. wispd talks to the native messaging host `wisp native-host`,
// which relays messages over the daemon's unix socket. This worker answers the daemon's requests: it attaches
// chrome.debugger to the requested tab, forwards DevTools Protocol commands, and streams the tab's events back.
// The extension itself never reads or stores page content.
//
// Wire format (both directions, JSON):
//   daemon -> extension  {type: "request", id, op, ...}   ops: ping, tabs, attach, detach, detachAll, cdp, activate, new, close
//   extension -> daemon  {type: "hello", ...} once per connection
//                        {type: "result", id, result} | {type: "result", id, error}
//                        {type: "event", tabId, method, params}   chrome.debugger events
//                        {type: "detached", tabId, reason}         the debugger detached (user cancelled, DevTools opened, tab gone)
//                        {type: "tabRemoved", tabId}
//   host -> extension    {type: "daemon", state: "connected" | "unavailable", version?, error?}

const HOST_NAME = "sb.moe.wisp";
const RECONNECT_ALARM = "wisp-reconnect";
const MIN_BACKOFF_MS = 1000;
const MAX_BACKOFF_MS = 30000;
// Commands that need the tab to be visible: screenshots of a background tab fail, and the user should see the
// tab Wisp is acting in.
const NEEDS_VISIBLE_PREFIXES = ["Page.captureScreenshot", "Input."];

let port = null;
let backoffMs = MIN_BACKOFF_MS;
let reconnectTimer = null;
const attached = new Set();
const status = { state: "disconnected", host: HOST_NAME, daemon: null, error: null, since: null };

function errorMessage(e) {
  if (e && typeof e.message === "string") return e.message;
  return String(e);
}

function setStatus(state, extra = {}) {
  Object.assign(status, extra);
  status.state = state;
  updateBadge();
}

function updateBadge() {
  const connected = status.state === "connected";
  const title = connected
    ? `Wisp: connected (wispd ${status.daemon || "?"})`
    : `Wisp: ${status.state}${status.error ? " - " + status.error : ""}`;
  chrome.action.setBadgeText({ text: connected ? "" : "!" }).catch(() => {});
  chrome.action.setBadgeBackgroundColor({ color: "#c4392b" }).catch(() => {});
  chrome.action.setTitle({ title }).catch(() => {});
}

function browserInfo() {
  const brands = (navigator.userAgentData && navigator.userAgentData.brands) || [];
  const known = brands.find((b) => /Google Chrome|Chromium|Brave|Microsoft Edge|Arc|Vivaldi|Opera/.test(b.brand));
  const fallback = brands.find((b) => !/Not.A.Brand/i.test(b.brand));
  const b = known || fallback;
  return { name: b ? b.brand : "Chrome", version: b ? b.version : "" };
}

function send(msg) {
  if (!port) return false;
  try {
    port.postMessage(msg);
    return true;
  } catch (e) {
    return false;
  }
}

function connect() {
  if (port) return true;
  if (reconnectTimer) {
    clearTimeout(reconnectTimer);
    reconnectTimer = null;
  }
  let p;
  try {
    p = chrome.runtime.connectNative(HOST_NAME);
  } catch (e) {
    setStatus("disconnected", { error: errorMessage(e) });
    scheduleReconnect();
    return false;
  }
  port = p;
  setStatus("connecting", { error: null, daemon: null });
  p.onMessage.addListener((msg) => {
    if (port === p) onHostMessage(msg);
  });
  p.onDisconnect.addListener(() => {
    if (port !== p) return;
    port = null;
    const err = (chrome.runtime.lastError && chrome.runtime.lastError.message) || null;
    setStatus("disconnected", { error: err, daemon: null, since: null });
    scheduleReconnect(err);
  });
  send({
    type: "hello",
    extensionVersion: chrome.runtime.getManifest().version,
    extensionId: chrome.runtime.id,
    browser: browserInfo(),
    userAgent: navigator.userAgent,
  });
  return true;
}

function scheduleReconnect(err) {
  if (reconnectTimer) return;
  // A missing host (not installed yet) is not worth hammering: the alarm retries every 30 s.
  const missing = err && /not found|not installed|forbidden/i.test(err);
  const delay = missing ? MAX_BACKOFF_MS : backoffMs;
  backoffMs = Math.min(MAX_BACKOFF_MS, backoffMs * 2);
  reconnectTimer = setTimeout(() => {
    reconnectTimer = null;
    connect();
  }, delay);
}

function onHostMessage(msg) {
  if (!msg || typeof msg !== "object") return;
  switch (msg.type) {
    case "daemon":
      if (msg.state === "connected") {
        backoffMs = MIN_BACKOFF_MS;
        setStatus("connected", { daemon: msg.version || "", error: null, since: Date.now() });
      } else {
        setStatus("disconnected", { error: msg.error || "wispd unavailable", daemon: null });
      }
      return;
    case "request":
      handleRequest(msg);
      return;
    default:
      return;
  }
}

async function handleRequest(req) {
  const id = req.id;
  try {
    const result = await dispatch(req);
    send({ type: "result", id, result: result === undefined ? {} : result });
  } catch (e) {
    send({ type: "result", id, error: errorMessage(e) });
  }
}

async function dispatch(req) {
  switch (req.op) {
    case "ping":
      return { ok: true, attached: [...attached] };
    case "tabs":
      return { tabs: await listTabs() };
    case "attach":
      await ensureAttached(needTab(req));
      return { ok: true };
    case "detach":
      await detach(needTab(req));
      return { ok: true };
    case "detachAll": {
      const ids = [...attached];
      for (const t of ids) await detach(t).catch(() => {});
      return { ok: true, count: ids.length };
    }
    case "cdp":
      return await cdp(needTab(req), req.method, req.params || {});
    case "activate":
      return await activate(needTab(req), !!req.focusWindow);
    case "new":
      return await newTab(req.url, req.active !== false);
    case "close":
      await chrome.tabs.remove(needTab(req));
      return { ok: true };
    default:
      throw new Error(`unknown op ${req.op}`);
  }
}

function needTab(req) {
  if (typeof req.tabId !== "number") throw new Error(`${req.op} needs a numeric tabId`);
  return req.tabId;
}

async function ensureAttached(tabId) {
  if (attached.has(tabId)) return;
  try {
    await chrome.debugger.attach({ tabId }, "1.3");
  } catch (e) {
    const m = errorMessage(e);
    // Attached by us before the worker restarted: keep going, commands will tell if it is really someone else.
    if (!/already attached/i.test(m)) throw new Error(m);
  }
  attached.add(tabId);
  await ensureActive(tabId).catch(() => {});
}

async function detach(tabId) {
  try {
    await chrome.debugger.detach({ tabId });
  } finally {
    attached.delete(tabId);
  }
}

async function ensureActive(tabId) {
  const t = await chrome.tabs.get(tabId);
  if (!t.active) await chrome.tabs.update(tabId, { active: true });
}

async function cdp(tabId, method, params) {
  if (typeof method !== "string") throw new Error("cdp needs a method");
  await ensureAttached(tabId);
  if (NEEDS_VISIBLE_PREFIXES.some((p) => method.startsWith(p))) await ensureActive(tabId).catch(() => {});
  try {
    const r = await chrome.debugger.sendCommand({ tabId }, method, params);
    return r === undefined ? {} : r;
  } catch (e) {
    const m = errorMessage(e);
    if (/not attached|no target with given id|detached/i.test(m)) attached.delete(tabId);
    throw new Error(m);
  }
}

function tabInfo(t, focusedWindowId) {
  return {
    id: t.id,
    title: t.title || "",
    url: t.url || t.pendingUrl || "",
    active: !!t.active,
    windowId: t.windowId,
    windowFocused: t.windowId === focusedWindowId,
    index: t.index,
    status: t.status || "",
    attached: attached.has(t.id),
  };
}

async function focusedWindowId() {
  try {
    const w = await chrome.windows.getLastFocused({ windowTypes: ["normal"] });
    return w ? w.id : null;
  } catch (e) {
    return null;
  }
}

async function listTabs() {
  const focused = await focusedWindowId();
  const wins = await chrome.windows.getAll({ populate: true, windowTypes: ["normal"] });
  // The last focused window first, the active tab of each window first.
  wins.sort((a, b) => Number(b.id === focused) - Number(a.id === focused));
  const out = [];
  for (const w of wins) {
    const tabs = [...(w.tabs || [])].sort((a, b) => Number(b.active) - Number(a.active) || a.index - b.index);
    for (const t of tabs) out.push(tabInfo(t, focused));
  }
  return out;
}

async function newTab(url, active) {
  const target = url || "about:blank";
  const windowId = await focusedWindowId();
  let t;
  if (windowId != null) {
    t = await chrome.tabs.create({ url: target, active, windowId });
  } else {
    const w = await chrome.windows.create({ url: target, focused: false });
    t = w.tabs && w.tabs[0];
    if (!t) throw new Error("could not create a window");
  }
  return tabInfo(t, windowId);
}

async function activate(tabId, focusWindow) {
  const t = await chrome.tabs.update(tabId, { active: true });
  if (focusWindow) await chrome.windows.update(t.windowId, { focused: true });
  return { ok: true, windowId: t.windowId };
}

chrome.debugger.onEvent.addListener((source, method, params) => {
  if (source.tabId == null) return;
  send({ type: "event", tabId: source.tabId, method, params: params || {} });
});

chrome.debugger.onDetach.addListener((source, reason) => {
  if (source.tabId == null) return;
  attached.delete(source.tabId);
  send({ type: "detached", tabId: source.tabId, reason: reason || "" });
});

chrome.tabs.onRemoved.addListener((tabId) => {
  attached.delete(tabId);
  send({ type: "tabRemoved", tabId });
});

chrome.runtime.onMessage.addListener((msg, sender, reply) => {
  if (!msg || typeof msg !== "object") return;
  if (msg.type === "status") {
    reply({
      ...status,
      attached: attached.size,
      extensionId: chrome.runtime.id,
      version: chrome.runtime.getManifest().version,
    });
    return;
  }
  if (msg.type === "reconnect") {
    backoffMs = MIN_BACKOFF_MS;
    if (port) {
      try {
        port.disconnect();
      } catch (e) {}
      port = null;
    }
    reply({ ok: connect() });
    return;
  }
});

// The service worker is stopped after 30 s without events; the daemon pings every 20 s while connected, and this
// alarm reconnects after a restart or once the host is installed.
chrome.alarms.create(RECONNECT_ALARM, { periodInMinutes: 0.5 });
chrome.alarms.onAlarm.addListener((a) => {
  if (a.name === RECONNECT_ALARM && !port) connect();
});
chrome.runtime.onInstalled.addListener(() => connect());
chrome.runtime.onStartup.addListener(() => connect());
connect();
