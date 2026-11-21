"use strict";

const $ = id => document.getElementById(id);
const labels = {add: "Add", edit: "Edit", check: "Check", update: "Update", reinstall: "Reinstall",
                remove: "Remove", start: "Start", stop: "Stop", restart: "Restart"};
let api;
const state = {connected: false, apps: [], runs: [], view: "apps",
               filter: "all", selected: null, cursor: -1, stream: null, text: "", replaceLine: false,
               prompt: null, detail: null, detailMode: "logs", detailRequest: 0, refresh: 0, starting: false};

function element(tag, text, css) {
  const node = document.createElement(tag);
  if (text !== undefined) node.textContent = text;
  if (css) node.className = css;
  return node;
}
function button(label, action, disabled = false) {
  const node = element("button", label);
  node.type = "button";
  node.disabled = disabled;
  node.addEventListener("click", action);
  return node;
}
function notify(message = "") {
  $("notice").textContent = message;
  $("notice").hidden = !message;
}
function busy() { return !state.connected || state.starting || state.runs.some(run => run.code === null); }
function runState(run) {
  if (run.code === null) return [run.cancelling ? "Cancelling" : "Running", "waiting"];
  if (run.code === 0) return ["Completed", "good"];
  if (run.action === "check" && run.code === 10) return ["Update available", "waiting"];
  if (run.cancelling || [129, 130, 143, -2, -15].includes(run.code)) return ["Cancelled", "muted"];
  return ["Failed · " + run.code, "bad"];
}
function serviceState(app) {
  if (app.state === "active") return [app.sub === "running" ? "Running" : "Active", "good"];
  if (app.sub === "auto-restart" && app.result && app.result !== "success") return ["Restarting", "bad"];
  if (app.pending && app.state === "inactive") return ["Awaiting install", "waiting"];
  if (["failed", "missing", "error", "unavailable", "masked", "bad-setting", "invalid service"].includes(app.state))
    return [app.state, "bad"];
  if (["activating", "reloading", "deactivating", "refreshing"].includes(app.state)) return [app.state, "waiting"];
  return [app.state, "muted"];
}
function badge([label, kind]) {
  return element("span", label.charAt(0).toUpperCase() + label.slice(1), "badge " + kind);
}
function toggleView(view) {
  state.view = view;
  $("apps-view").hidden = view !== "apps";
  $("history-view").hidden = view !== "history";
  for (const v of ["apps", "history"]) {
    const tab = $("nav-" + v);
    tab.classList.toggle("active", view === v);
    if (v === view) tab.setAttribute("aria-current", "page");
    else tab.removeAttribute("aria-current");
  }
}
function cell(row, text, css) {
  const td = element("td", text, css);
  row.append(td);
  return td;
}
function renderApps() {
  const term = $("search").value.trim().toLowerCase();
  const visible = state.apps.filter(app => {
    if (state.filter === "active" && app.state !== "active") return false;
    if (state.filter === "issues" && serviceState(app)[1] !== "bad") return false;
    return [app.name, app.repo, app.service].some(s => (s || "").toLowerCase().includes(term));
  });
  const rows = document.createDocumentFragment();
  const locked = busy();
  for (const id of ["check-all", "update-all", "add"]) $(id).disabled = locked;
  for (const app of visible) {
    const row = element("tr");
    const name = cell(row);
    name.append(element("strong", app.name), element("small", app.repo || ""));
    cell(row, app.version || "Unknown", "version");
    const unit = cell(row, app.service || "—");
    if (app.service) unit.append(element("small", app.scope + " service"));
    const status = cell(row);
    status.append(badge(serviceState(app)));
    if (app.result && app.result !== "success") status.append(element("small", app.result));
    status.title = [app.state, app.sub, app.result].filter(Boolean).join(" / ");
    const actions = element("div", undefined, "row-actions");
    actions.append(button("Update", () => startRun("update", app.name), locked));
    if (app.service) actions.append(button("Logs", () => openDetail(app, "logs")));
    const details = element("details");
    const more = element("summary", "More");
    more.setAttribute("aria-label", "More actions for " + app.name);
    details.append(more);
    const menu = element("div", undefined, "dropdown");
    function item(label, action, disabled = locked) {
      menu.append(button(label, () => { details.open = false; action(); }, disabled));
    }
    item("Check for updates", () => startRun("check", app.name));
    item("Edit settings", () => startRun("edit", app.name));
    if (app.service) item("Service status", () => openDetail(app, "status"), false);
    item("Force reinstall", () => startRun("reinstall", app.name));
    item("Remove from registry", () => {
      if (confirm("Remove " + app.name + " from the registry? Its binary and systemd unit stay on the server."))
        startRun("remove", app.name);
    });
    details.append(menu);
    actions.append(details);
    cell(row).append(actions);
    rows.append(row);
  }
  $("apps").replaceChildren(rows);
  $("apps-empty").hidden = visible.length !== 0;
  $("apps-empty").textContent = !state.connected ? "Waiting for Binup…" :
    (state.apps.length ? "No apps match this filter." : "No applications registered.");
  for (const id of ["start-unit", "restart-unit", "stop-unit"]) $(id).disabled = locked;
}
function renderHistory() {
  const rows = state.runs.map(run => {
    const row = button("", () => selectRun(run.id, true));
    row.className = "history-row";
    row.append(element("strong", labels[run.action] + " · " + run.target), badge(runState(run)),
               element("time", new Date(run.started * 1000).toLocaleString()));
    return row;
  });
  $("history").replaceChildren(...(rows.length ? rows : [element("p", "No runs in this server session.", "empty")]));
}

async function refreshState() {
  if (state.starting) return;
  const seq = ++state.refresh;
  const data = await api("state");
  if (seq !== state.refresh) return;
  const previous = JSON.stringify(state.apps), wasBusy = busy();
  if (!state.connected) notify();
  state.connected = true;
  state.apps = data.apps;
  state.runs = data.runs;
  // Keep open row menus and keyboard focus during an ordinary status refresh.
  if (previous !== JSON.stringify(state.apps) || wasBusy !== busy() || !$("apps").childElementCount) renderApps();
  renderHistory();
  if (state.selected && !state.runs.some(r => r.id === state.selected)) clearRun();
  if (!state.selected && state.runs.length) selectRun(state.runs[0].id);
  $("connection").textContent = "Connected";
  $("connection").classList.remove("offline");
}
function reportConnection(error) {
  state.connected = false;
  renderApps();
  $("connection").textContent = "Disconnected";
  $("connection").classList.add("offline");
  notify(error.message);
}
function clearRun() {
  if (state.stream) state.stream.abort();
  state.stream = null;
  state.selected = state.prompt = null;
  state.text = "";
  state.replaceLine = false;
  $("reply").hidden = $("cancel").hidden = $("run-caption").hidden = true;
  $("transcript").textContent = "Output appears here when you run a command.";
  $("run-badge").textContent = "Idle";
  $("run-badge").className = "badge muted";
}
async function startRun(action, app) {
  if (busy()) return;
  state.refresh++;
  state.starting = true;
  notify();
  renderApps();
  try {
    const run = await api("runs", {action, app});
    state.runs.unshift(run);
    selectRun(run.id, true);
    renderHistory();
  } catch (error) {
    notify(error.message);
    refreshState().catch(reportConnection);
  } finally { state.starting = false; renderApps(); }
}
function appendOutput(text, truncated) {
  const box = $("transcript");
  const atEnd = box.scrollHeight - box.scrollTop - box.clientHeight < 42;
  if (truncated) { state.text = "[Earlier output trimmed]\n"; state.replaceLine = false; }
  text = text.replace(/\x1b\[[0-?]*[ -/]*[@-~]/g, "").replace(/\r\n/g, "\n")
             .replace(/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/g, "");
  for (const part of text.split(/([\r\n])/)) {
    if (!part) continue;
    if (part === "\r") { state.replaceLine = true; continue; }
    if (state.replaceLine && part !== "\n") state.text = state.text.slice(0, state.text.lastIndexOf("\n") + 1);
    state.replaceLine = false;
    state.text += part;
  }
  state.text = state.text.slice(-262144);
  box.textContent = state.text || "Waiting for output…";
  if (atEnd || truncated) box.scrollTop = box.scrollHeight;
}
function showPrompt(prompt) {
  if (prompt && (!state.prompt || state.prompt.id !== prompt.id)) {
    $("prompt-label").textContent = prompt.label;
    $("answer").value = prompt.default;
    $("reply").hidden = false;
    if (!$("service-dialog").open && !$("add-dialog").open) $("answer").focus({preventScroll:true});
  } else if (!prompt) $("reply").hidden = true;
  state.prompt = prompt;
}
async function selectRun(id, scroll = false) {
  if (scroll) document.querySelector(".output").scrollIntoView({block:"nearest"});
  if (state.selected === id && state.stream) return;
  clearRun();
  state.selected = id;
  state.cursor = -1;
  const controller = new AbortController();
  state.stream = controller;
  while (!controller.signal.aborted) {
    try {
      const run = await api("runs/" + id + "?after=" + state.cursor, undefined, controller.signal);
      if (controller.signal.aborted) return;
      state.cursor = run.cursor;
      const status = runState(run);
      $("run-caption").hidden = false;
      $("run-caption").textContent = labels[run.action] + " · " + run.target;
      $("run-badge").textContent = status[0];
      $("run-badge").className = "badge " + status[1];
      $("cancel").hidden = run.code !== null;
      $("cancel").disabled = run.cancelling;
      appendOutput(run.output, run.truncated);
      showPrompt(run.prompt);
      if (run.code !== null) {
        const current = state.runs.find(item => item.id === id);
        if (current) Object.assign(current, {code:run.code, cancelling:run.cancelling});
        renderApps(); renderHistory();
        refreshState().catch(reportConnection);
        return;
      }
    } catch (error) {
      if (controller.signal.aborted) return;
      reportConnection(error);
      await new Promise(resolve => setTimeout(resolve, 1500));
    }
  }
}
async function loadDetail() {
  const app = state.detail;
  if (!app || !$("service-dialog").open) return;
  const mode = state.detailMode, seq = ++state.detailRequest;
  try {
    const data = await api(mode + "?app=" + encodeURIComponent(app.name));
    if (seq !== state.detailRequest || !$("service-dialog").open) return;
    const pre = $("detail-output"), pinned = pre.scrollHeight - pre.clientHeight - pre.scrollTop < 45;
    pre.textContent = data.output || (data.code ? "Command failed (exit " + data.code + ")." : "No journal entries.");
    if (mode === "logs" && pinned) pre.scrollTop = pre.scrollHeight;
  } catch (error) {
    if (seq === state.detailRequest) $("detail-output").textContent = error.message;
  }
}
function detailMode(mode) {
  state.detailMode = mode;
  for (const key of ["status", "logs"]) $("detail-" + key).classList.toggle("selected", key === mode);
  $("detail-output").textContent = "Loading…";
  loadDetail();
}
function openDetail(app, mode) {
  state.detail = app;
  $("detail-name").textContent = app.name;
  $("detail-unit").textContent = app.service + (app.service.endsWith(".service") ? "" : ".service") + " · " + app.scope;
  $("service-dialog").showModal();
  detailMode(mode);
}
$("nav-apps").addEventListener("click", () => toggleView("apps"));
$("nav-history").addEventListener("click", () => toggleView("history"));
$("add").addEventListener("click", () => { $("new-name").value = ""; $("add-dialog").showModal(); $("new-name").focus(); });
$("add-form").addEventListener("submit", e => {
  e.preventDefault(); const name = $("new-name").value.trim();
  if (name) { $("add-dialog").close(); startRun("add", name); }
});
for (const action of ["check", "update"]) $(action + "-all").addEventListener("click", () => startRun(action, "all"));
$("search").addEventListener("input", renderApps);
for (const node of document.querySelectorAll("[data-filter]")) node.addEventListener("click", () => {
  state.filter = node.dataset.filter;
  for (const el of document.querySelectorAll("[data-filter]")) {
    el.classList.toggle("selected", el === node);
    el.setAttribute("aria-pressed", String(el === node));
  }
  renderApps();
});
document.querySelectorAll("dialog .close").forEach(node => node.addEventListener("click", () => node.closest("dialog").close()));
$("cancel").addEventListener("click", async () => {
  try { await api("runs/" + state.selected + "/cancel", {}); } catch (error) { notify(error.message); }
});
$("reply").addEventListener("submit", async e => {
  e.preventDefault();
  if (!state.prompt) return;
  const prompt = state.prompt;
  try { await api("runs/" + state.selected + "/input", {id:prompt.id, value:$("answer").value}); }
  catch (error) { notify(error.message); }
});
for (const mode of ["status", "logs"]) $("detail-" + mode).addEventListener("click", () => detailMode(mode));
$("reload-detail").addEventListener("click", loadDetail);
$("follow").addEventListener("change", () => { if ($("follow").checked) loadDetail(); });
for (const action of ["start", "restart", "stop"]) $(action + "-unit").addEventListener("click", () => {
  if (!state.detail || busy()) return;
  if (action === "stop" && !confirm("Stop " + state.detail.service + "?")) return;
  $("service-dialog").close();
  startRun(action, state.detail.name);
});
async function watchApps() {
  try { if (!$("console").hidden && !document.hidden) await refreshState(); }
  catch (error) { reportConnection(error); }
  finally { setTimeout(watchApps, 8000); }
}
async function watchService() {
  try { if ($("service-dialog").open && $("follow").checked && !document.hidden) await loadDetail(); }
  finally { setTimeout(watchService, 2500); }
}
export function start(request, preferredTheme = () => "auto") {
  api = request;
  const media = window.matchMedia("(prefers-color-scheme: dark)");
  function applyTheme() {
    const theme = preferredTheme();
    document.documentElement.dataset.theme = theme === "auto" ? (media.matches ? "dark" : "light") : theme;
  }
  media.addEventListener("change", applyTheme);
  window.addEventListener("storage", applyTheme);
  applyTheme();
  renderApps();
  watchApps();
  watchService();
}
