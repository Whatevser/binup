"use strict";

const $ = id => document.getElementById(id);
const labels = {add: "Add", edit: "Edit", check: "Check", update: "Update", reinstall: "Reinstall", cleanup: "Clear backup",
                remove: "Remove", start: "Start", stop: "Stop", restart: "Restart"};
let api;
// Only the initiating tab can answer an interactive run, including after a refresh.
let ownedRun;
function rememberRun(run, key) {
  ownedRun = {id: run, key};
  try {
    if (key) sessionStorage.setItem("binup.run." + run, key);
    else sessionStorage.removeItem("binup.run." + run);
  } catch { /* In-memory access still works if browser storage is disabled. */ }
}
function ownerKey(run) {
  if (ownedRun?.id === run) return ownedRun.key;
  try { return sessionStorage.getItem("binup.run." + run); } catch { return null; }
}

const state = {connected: false, apps: [], runs: [], view: "apps",
               filter: "all", selected: null, cursor: -1, stream: null, text: "", replaceLine: false,
               prompt: null, workflow: null, dismissed: null, cleared: -1, journalSince: new Map(), settings: null, detail: null, detailMode: "logs", detailRequest: 0, refresh: 0, starting: false};

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
  if (["check", "auto"].includes(run.action) && run.code === 10) return ["Update available", "waiting"];
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
  $("settings-view").hidden = view !== "settings";
  document.querySelector(".output").hidden = view === "settings";
  for (const v of ["apps", "history", "settings"]) {
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
function versionCell(row, app) {
  const check = app.check;
  const current = check?.status === "current";
  const available = check?.status === "available";
  const latest = check?.latest;
  // A digest can confirm the actual installed build even when a legacy registry tag is missing.
  const td = cell(row, (current ? latest : app.version) || "Unknown", "version " +
    (current ? "good" : available ? "bad" : check ? "waiting" : "muted"));
  let label = "Not checked";
  if (current) label = "Up to date";
  else if (available && check.reason === "binary missing") label = "Install " + latest;
  else if (available && latest !== app.version) label = "Update to " + latest;
  else if (available) label = "Verification needed";
  else if (check) label = check.problem || "Check failed";
  if (available && check.problem) label += " · " + check.problem;
  td.append(element("small", label));
  if (check) td.title = ["Checked " + new Date(check.checked * 1000).toLocaleString(), check.reason].filter(Boolean).join(" · ");
}
function runLabel(run) {
  return (run.scheduled ? "Scheduled maintenance" : labels[run.action]) + " · " + run.target;
}
async function savePolicy(app, key, enabled) {
  if (busy()) return;
  try {
    await api("app-settings", {app, key, enabled});
    await refreshState();
  } catch (error) {
    notify(error.message);
    refreshState().catch(reportConnection);
  }
}
function renderApps() {
  const term = $("search").value.trim().toLowerCase();
  const visible = state.apps.filter(app => {
    if (state.filter === "active" && app.state !== "active") return false;
    if (state.filter === "issues" && serviceState(app)[1] !== "bad" && !["available", "error"].includes(app.check?.status)) return false;
    return [app.name, app.repo, app.service].some(s => (s || "").toLowerCase().includes(term));
  });
  const rows = document.createDocumentFragment();
  const locked = busy();
  for (const id of ["check-all", "update-all", "add"]) $(id).disabled = locked;
  $("clear-backups").disabled = locked || !state.apps.some(app => app.has_backup);
  for (const app of visible) {
    const row = element("tr");
    const name = cell(row);
    name.append(element("strong", app.name), element("small", app.repo || ""));
    versionCell(row, app);
    const unit = cell(row, app.service || "—");
    if (app.service) unit.append(element("small", app.scope + " service"));
    const status = cell(row);
    status.append(badge(serviceState(app)));
    if (app.result && app.result !== "success") status.append(element("small", app.result));
    status.title = [app.state, app.sub, app.result].filter(Boolean).join(" / ");
    const policyCell = cell(row);
    const toggle = element("label", undefined, "auto-toggle");
    const checkbox = element("input");
    checkbox.type = "checkbox";
    checkbox.checked = app.auto_update;
    checkbox.disabled = locked;
    checkbox.setAttribute("aria-label", "Automatically update " + app.name);
    checkbox.addEventListener("change", () => savePolicy(app.name, "auto_update", checkbox.checked));
    toggle.append(checkbox, element("span", app.auto_update ? "On" : "Off"));
    policyCell.append(toggle);
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
    item("Keep rollback backup: " + (app.keep_backup ? "On" : "Off"),
      () => savePolicy(app.name, "keep_backup", !app.keep_backup));
    item("Clear saved backup", () => {
      if (confirm("Delete " + app.name + "'s .bak rollback file? This cannot be undone."))
        startRun("cleanup", app.name);
    }, locked || !app.has_backup);
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
  $("clear-history").disabled = !state.runs.some(run => run.code !== null);
  const rows = state.runs.map(run => {
    const row = button("", () => selectRun(run.id, true));
    row.className = "history-row";
    row.append(element("strong", runLabel(run)), badge(runState(run)),
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
  const lastRun = state.runs[0]?.id;
  if (!state.connected) notify();
  state.connected = true;
  state.apps = data.apps;
  state.runs = data.runs;
  if (!state.settings || state.settings.interval_hours !== data.settings.interval_hours)
    $("interval").value = String(data.settings.interval_hours);
  showSettings(data.settings);
  // Keep open row menus and keyboard focus during an ordinary status refresh.
  if (previous !== JSON.stringify(state.apps) || wasBusy !== busy() || !$("apps").childElementCount) renderApps();
  renderHistory();
  if (state.selected && !state.runs.some(r => r.id === state.selected)) clearRun();
  const selected = state.runs.find(r => r.id === state.selected);
  if (selected && selected.code !== null && selected.cleared > state.cleared) selectRun(selected.id, false, true);
  const latest = state.runs[0];
  if (latest && (!state.selected || (latest.id !== lastRun && state.selected === lastRun && state.view === "apps")))
    selectRun(latest.id);
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
  $("sudo-password").value = "";
  if (state.stream) state.stream.abort();
  state.stream = null;
  state.selected = state.prompt = null;
  state.workflow = state.dismissed = null;
  state.cleared = -1;
  $("resume").hidden = true;
  $("clear-output").disabled = true;
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
    const run = await api("runs", {action, app, interactive_sudo:true});
    if (run.owner) { rememberRun(run.id, run.owner); delete run.owner; }
    state.runs.unshift(run);
    selectRun(run.id, action !== "add" && action !== "edit");
    if (["add", "edit"].includes(action)) beginWorkflow(run);
    renderHistory();
  } catch (error) {
    if ($("setup-dialog").open) stepError(error.message);
    else notify(error.message);
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
  box.textContent = state.text || (state.cleared >= 0 ? "Output cleared." : "Waiting for output…");
  if (atEnd || truncated) box.scrollTop = box.scrollHeight;
}
function stepError(text = "") {
  $("step-error").textContent = text;
  $("step-error").hidden = !text;
}
function openSetup() {
  if (!$("setup-dialog").open) $("setup-dialog").showModal();
}
function beginWorkflow(run, target = run.target) {
  state.workflow = run.id;
  $("setup-title").textContent = (run.action === "add" ? "Add " : run.action === "edit" ? "Edit " : "Select build for ") + target;
  $("add-form").hidden = true;
  $("stop-setup").hidden = false;
  $("step-status").hidden = false;
  $("step-status").textContent = "Loading…";
  stepError();
  openSetup();
}
function showPrompt(prompt, run) {
  if (!prompt) {
    $("sudo-password").value = "";
    $("reply").hidden = $("resume").hidden = true;
    if (state.workflow === run.id && run.code === null) {
      $("step-status").hidden = false;
      $("step-status").textContent = "Working…";
    }
  } else if (state.prompt?.id !== prompt.id) {
    if (state.workflow !== run.id) beginWorkflow(run, prompt.app || run.target);
    else if (run.action === "update" || run.action === "reinstall") $("setup-title").textContent = "Select build for " + (prompt.app || run.target);
    if (prompt.secret) $("setup-title").textContent = "Authorize " + runLabel(run);
    if (state.dismissed !== run.id) openSetup();
    stepError(prompt.retry ? "Sudo is asking again. Re-enter your password." : "");
    $("step-status").hidden = true;
    $("reply").hidden = false;
    $("resume").hidden = $("setup-dialog").open;
    $("prompt-label").textContent = prompt.label;
    $("prompt-hint").textContent = prompt.secret ?
      [prompt.app, prompt.hint].filter(Boolean).join(" · ") : prompt.hint;
    $("next-step").textContent = prompt.secret ? "Authorize" : "Continue";
    $("resume").textContent = prompt.secret ? "Enter sudo password" : "Resume setup";
    const choices = prompt.options.length > 0;
    const field = prompt.secret ? $("sudo-password") : choices ? $("choice") : $("answer");
    $("sudo-password").value = "";
    $("prompt-label").htmlFor = field.id;
    for (const id of ["answer", "choice", "sudo-password"]) {
      const control = $(id);
      control.hidden = control.disabled = control !== field;
    }
    if (choices) {
      const options = prompt.options.map(o => typeof o === "string" ? new Option(o, o) : new Option(o.label, o.value));
      if (!options.some(o => o.value === prompt.default)) {
        const placeholder = new Option("Choose an option…", "");
        placeholder.disabled = true;
        options.unshift(placeholder);
      }
      field.replaceChildren(...options);
    }
    field.required = prompt.required;
    field.value = prompt.default;
    $("next-step").disabled = false;
    if ($("setup-dialog").open) field.focus({preventScroll:true});
  }
  state.prompt = prompt;
}
function finishWorkflow(run) {
  if (state.workflow !== run.id) return;
  $("stop-setup").hidden = $("step-status").hidden = true;
  if (run.code !== 0 && !run.cancelling) {
    const errors = state.text.split("\n").filter(line => line.startsWith("! ") || line.startsWith("sudo:"));
    stepError(errors.slice(-3).join("\n") || state.text.trim().split("\n").pop() || "Setup failed.");
  } else $("setup-dialog").close();
  state.workflow = null;
}
async function selectRun(id, scroll = false, reload = false) {
  if (scroll) document.querySelector(".output").scrollIntoView({block:"nearest"});
  if (state.selected === id && state.stream && !reload) return;
  clearRun();
  state.selected = id;
  state.cursor = -1;
  const controller = new AbortController();
  state.stream = controller;
  while (!controller.signal.aborted) {
    try {
      const run = await api("runs/" + id + "?after=" + state.cursor, undefined, controller.signal, ownerKey(id));
      if (controller.signal.aborted) return;
      if (state.cleared < run.cleared) { state.text = ""; state.replaceLine = false; }
      state.cleared = run.cleared;
      state.cursor = run.cursor;
      const status = runState(run);
      $("run-caption").hidden = false;
      $("run-caption").textContent = runLabel(run) + (run.waiting_for_owner ? " · Waiting for the tab that started this run" : "");
      $("clear-output").disabled = false;
      $("run-badge").textContent = status[0];
      $("run-badge").className = "badge " + status[1];
      $("cancel").hidden = run.code !== null;
      $("cancel").disabled = run.cancelling;
      appendOutput(run.output, run.truncated);
      showPrompt(run.prompt, run);
      if (run.code !== null) {
        finishWorkflow(run);
        if (ownerKey(id)) rememberRun(id, null);
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
    const since = state.journalSince.get(app.name);
    const data = await api(mode + "?app=" + encodeURIComponent(app.name) +
      (mode === "logs" && since ? "&since=" + since : ""));
    if (seq !== state.detailRequest || !$("service-dialog").open) return;
    const pre = $("detail-output"), pinned = pre.scrollHeight - pre.clientHeight - pre.scrollTop < 45;
    pre.textContent = data.output || (data.code ? "Command failed (exit " + data.code + ")." : since && mode === "logs" ? "Waiting for new journal entries…" : "No journal entries.");
    if (mode === "logs" && pinned) pre.scrollTop = pre.scrollHeight;
  } catch (error) {
    if (seq === state.detailRequest) $("detail-output").textContent = error.message;
  }
}
function detailMode(mode) {
  state.detailMode = mode;
  $("clear-journal").hidden = mode !== "logs";
  $("earlier-journal").hidden = mode !== "logs" || !state.journalSince.has(state.detail.name);
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
$("nav-settings").addEventListener("click", () => toggleView("settings"));
$("add").addEventListener("click", () => {
  $("setup-title").textContent = "Add an application";
  $("new-name").value = "";
  $("add-form").hidden = false;
  $("reply").hidden = $("stop-setup").hidden = $("step-status").hidden = true;
  stepError(); openSetup(); $("new-name").focus();
});
$("add-form").addEventListener("submit", e => {
  e.preventDefault(); const name = $("new-name").value.trim();
  if (name) startRun("add", name);
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
async function cancelSelected() {
  try { await api("runs/" + state.selected + "/cancel", {}); }
  catch (error) { if ($("setup-dialog").open) stepError(error.message); else notify(error.message); }
}
$("cancel").addEventListener("click", cancelSelected);
$("stop-setup").addEventListener("click", cancelSelected);
$("setup-dialog").addEventListener("close", () => {
  $("sudo-password").value = "";
  if (state.workflow) { state.dismissed = state.workflow; $("resume").hidden = !state.prompt; }
});
$("resume").addEventListener("click", () => { state.dismissed = null; $("resume").hidden = true; openSetup(); });
$("reply").addEventListener("submit", async e => {
  e.preventDefault();
  const prompt = state.prompt;
  if (!prompt || $("next-step").disabled) return;
  $("next-step").disabled = true;
  const field = $(prompt.secret ? "sudo-password" : prompt.options.length ? "choice" : "answer");
  const value = field.value;
  if (prompt.secret) field.value = "";
  try {
    const path = "runs/" + state.selected + (prompt.secret ? "/password" : "/input");
    await api(path, {id:prompt.id, value}, undefined, ownerKey(state.selected));
  }
  catch (error) {
    if (state.prompt?.id === prompt.id) { $("next-step").disabled = false; stepError(error.message); }
  }
});
$("clear-output").addEventListener("click", async () => {
  const id = state.selected;
  try {
    await api("runs/" + id + "/clear", {});
    if (state.selected !== id) return;
    const selected = state.runs.find(r => r.id === id);
    if (selected && selected.code !== null) selectRun(id, false, true);
  } catch (error) { notify(error.message); }
});
$("clear-history").addEventListener("click", async () => {
  try { await api("history/clear", {}); await refreshState(); }
  catch (error) { notify(error.message); }
});
$("clear-journal").addEventListener("click", async () => {
  const app = state.detail;
  try {
    const {since} = await api("logs/clear-view", {});
    state.journalSince.set(app.name, since);
    if (state.detail === app && state.detailMode === "logs") detailMode("logs");
  } catch (error) { notify(error.message); }
});
$("earlier-journal").addEventListener("click", () => { state.journalSince.delete(state.detail.name); detailMode("logs"); });
function showSettings(settings) {
  state.settings = settings;
  $("schedule-status").textContent = !settings.interval_hours ? "Automatic checks are off." :
    settings.next_check * 1000 <= Date.now() ? "A check is due when Binup is idle." :
      "Next check: " + new Date(settings.next_check * 1000).toLocaleString();
}
$("clear-backups").addEventListener("click", () => {
  if (busy()) return;
  const count = state.apps.filter(app => app.has_backup).length;
  if (!count || !confirm("Delete saved .bak rollback files for " + count + " registered app(s)? This cannot be undone.")) return;
  toggleView("apps");
  startRun("cleanup", "all");
});
$("schedule-form").addEventListener("submit", async e => {
  e.preventDefault();
  $("save-schedule").disabled = true;
  try { showSettings(await api("settings", {interval_hours:Number($("interval").value)})); }
  catch (error) { notify(error.message); }
  finally { $("save-schedule").disabled = false; }
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
