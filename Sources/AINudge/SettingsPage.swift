// The settings page, served by WebServer. Kept in Swift so the app is a single binary; the CSS and
// script are separate files so the page works under a strict Content-Security-Policy.
let settingsPage = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>AI Nudge</title>
<link rel="stylesheet" href="app.css">
</head>
<body>
<main>
  <header>
    <h1>AI Nudge</h1>
    <span id="access" class="pill"></span>
    <span id="sending" class="pill" hidden></span>
    <span id="awake" class="pill ok" hidden></span>
    <span id="saved" class="saved">Saved</span>
  </header>

  <div id="axwarn" class="card warnbox" hidden>
    <strong>AI Nudge can't type yet.</strong> On the Mac, turn on AI Nudge in System Settings › Privacy &amp; Security ›
    Accessibility (if it's already on, turn it off and on again). Until then nothing gets sent.
  </div>
  <section id="nudges" aria-label="Nudges"></section>
  <button id="add" class="primary">Add nudge</button>

  <h2>Settings</h2>
  <div class="card">
    <div class="grid">
      <label>Browser for web chats<select id="browser"></select></label>
      <label>Wait after opening a chat (seconds)<input id="settle" type="number" min="1" max="30" step="0.5"></label>
      <label>Send late if the Mac was asleep, up to (minutes)<input id="catchup" type="number" min="0" max="1440" step="5"></label>
      <div>
        <label class="check"><input id="restore" type="checkbox"> Go back to the app I was using</label>
        <label class="check"><input id="lan" type="checkbox"> Let other devices on my network open this page</label>
      </div>
      <label>Address on your own site (optional, see README)<input id="public" type="text" placeholder="https://example.com/ainudge/"></label>
    </div>
    <p id="lanlink" class="hint" hidden></p>
  </div>

  <h2>Keep awake</h2>
  <div class="card">
    <div class="row">
      <label class="grow">Keep the Mac awake<select id="awakeFor">
        <option value="0">Off</option>
        <option value="-1">Until after the next nudge</option>
        <option value="forever">Indefinitely</option>
        <option value="60">1 hour</option>
        <option value="180">3 hours</option>
        <option value="480">8 hours</option>
      </select></label>
      <button id="awakeStop" hidden>Stop</button>
    </div>
    <label class="check"><input id="awakeDisplay" type="checkbox"> Let the display sleep, just keep the Mac awake</label>
    <label class="check"><input id="awakeBattery" type="checkbox"> Stop when the battery is below 10%</label>
    <p class="hint">A nudge can only type while the screen is unlocked, so if your Mac locks when the display sleeps, keep the display awake too.</p>
  </div>

  <h2>Activity</h2>
  <div class="card"><div id="log" class="log"></div></div>
</main>

<script src="app.js"></script>
</body>
</html>
"""#

let settingsCSS = #"""
:root {
  --bg: #f6f6f4; --card: #ffffff; --ink: #1c1c1a; --muted: #6b6b66; --line: #e2e2dc;
  --accent: #c2410c; --accent-ink: #ffffff; --ok: #15803d; --warn: #b45309; --chip: #efefea;
  color-scheme: light;
}
@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) {
    --bg: #161615; --card: #20201e; --ink: #ececea; --muted: #9a9a94; --line: #34342f;
    --accent: #fb923c; --accent-ink: #1c1206; --ok: #4ade80; --warn: #fbbf24; --chip: #2b2b28;
    color-scheme: dark;
  }
}
* { box-sizing: border-box; }
[hidden] { display: none !important; }
body { margin: 0; background: var(--bg); color: var(--ink); font: 15px/1.45 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
main { max-width: 720px; margin: 0 auto; padding: 28px 16px 64px; }
header { display: flex; align-items: center; gap: 12px; flex-wrap: wrap; margin-bottom: 20px; }
h1 { font-size: 22px; margin: 0; letter-spacing: -0.01em; }
h2 { font-size: 13px; text-transform: uppercase; letter-spacing: 0.06em; color: var(--muted); margin: 32px 0 10px; font-weight: 600; }
.pill { font-size: 12.5px; padding: 3px 10px; border-radius: 99px; background: var(--chip); color: var(--muted); }
.pill.ok { color: var(--ok); } .pill.warn { color: var(--warn); }
.saved { margin-left: auto; font-size: 12.5px; color: var(--muted); transition: opacity .3s; opacity: 0; }
.card { background: var(--card); border: 1px solid var(--line); border-radius: 12px; padding: 14px; margin-bottom: 12px; }
.card.off { opacity: .62; }
.warnbox { border-color: var(--warn); color: var(--ink); font-size: 14px; }
.warnbox strong { color: var(--warn); }
.row { display: flex; gap: 10px; align-items: center; flex-wrap: wrap; }
.row + .row, .row + label, label + label, .card > label, .card > .hint { margin-top: 10px; }
.card > textarea { margin-top: 4px; }
.card > * + .row { margin-top: 10px; }
label { display: block; font-size: 12.5px; color: var(--muted); }
label > input, label > select, label > textarea { margin-top: 4px; }
input, select, textarea, button { font: inherit; color: inherit; }
input[type=text], input[type=time], input[type=number], select, textarea {
  width: 100%; background: var(--bg); border: 1px solid var(--line); border-radius: 8px; padding: 7px 9px;
}
textarea { resize: vertical; min-height: 58px; }
input:focus-visible, select:focus-visible, textarea:focus-visible, button:focus-visible { outline: 2px solid var(--accent); outline-offset: 1px; }
.row input.name { flex: 1 1 160px; width: auto; font-weight: 600; }
.row input.time { flex: 0 0 118px; width: 118px; }
button { cursor: pointer; border: 1px solid var(--line); background: var(--card); border-radius: 8px; padding: 7px 12px; }
button.primary { background: var(--accent); color: var(--accent-ink); border-color: transparent; font-weight: 600; }
button.ghost { border-color: transparent; background: none; color: var(--muted); padding: 7px 8px; }
button:disabled { opacity: .5; cursor: default; }
.days { display: flex; gap: 6px; flex-wrap: wrap; }
.days button { padding: 4px 0; width: 42px; font-size: 13px; background: var(--chip); border-color: transparent; color: var(--muted); }
.days button[aria-pressed=true] { background: var(--accent); color: var(--accent-ink); }
.switch { position: relative; width: 38px; height: 22px; flex: 0 0 auto; }
.switch input { opacity: 0; width: 100%; height: 100%; margin: 0; cursor: pointer; position: absolute; z-index: 1; }
.switch span { position: absolute; inset: 0; border-radius: 99px; background: var(--line); transition: background .15s; }
.switch span::after { content: ""; position: absolute; top: 3px; left: 3px; width: 16px; height: 16px; border-radius: 50%; background: #fff; transition: transform .15s; }
.switch input:checked + span { background: var(--accent); }
.switch input:checked + span::after { transform: translateX(16px); }
.switch input:focus-visible + span { outline: 2px solid var(--accent); outline-offset: 2px; }
.meta { font-size: 12.5px; color: var(--muted); margin-top: 10px; }
.meta.bad { color: var(--warn); }
.grid { display: grid; grid-template-columns: 1fr 1fr; gap: 10px 14px; }
.check { display: flex; gap: 8px; align-items: center; color: var(--ink); font-size: 14px; }
.check input { width: 16px; height: 16px; margin: 0; }
.card > .check { margin-top: 10px; }
.grow { flex: 1 1 auto; }
.log { font: 12px/1.6 ui-monospace, SFMono-Regular, Menlo, monospace; color: var(--muted); white-space: pre-wrap; word-break: break-word; max-height: 240px; overflow: auto; }
.hint { font-size: 12.5px; color: var(--muted); margin: 6px 0 0; }
code { font: 12px ui-monospace, Menlo, monospace; background: var(--chip); padding: 1px 5px; border-radius: 4px; word-break: break-all; }
.grid > label > input, .grid > label > select { margin-top: 4px; }
.grid { align-items: end; }
@media (max-width: 520px) { .grid { grid-template-columns: 1fr; } .row input.time { flex: 1 1 100%; }
  .days { flex: 1 1 100%; flex-wrap: nowrap; gap: 4px; } .days button { flex: 1 1 0; width: auto; min-width: 0; padding: 4px 0; } }
"""#

let settingsJS = #"""
const token = new URLSearchParams(location.search).get("t") || "";
const DAY = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
let S = null, saveTimer = null;
// Fresh status from the app, keeping the settings being edited here (the cards hold on to them).
const merge = fresh => { S = S ? { ...fresh, config: S.config } : fresh; status(); };

async function api(method, path, body) {
  // Relative, so the page also works behind a reverse proxy at a sub-path (e.g. /ainudge/).
  const r = await fetch(path.replace(/^\//, ""), { method, headers: { "X-Token": token, "Content-Type": "application/json" }, body: body && JSON.stringify(body) });
  if (!r.ok) throw new Error(await r.text());
  return r.json();
}
const el = (tag, attrs = {}, ...kids) => {
  const e = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) k.startsWith("on") ? e.addEventListener(k.slice(2), v) : e.setAttribute(k, v);
  e.append(...kids);
  return e;
};

function save() {
  clearTimeout(saveTimer);
  saveTimer = setTimeout(async () => {
    saveTimer = null;
    merge(await api("PUT", "/api/config", S.config));
    const s = document.getElementById("saved");
    s.style.opacity = 1; setTimeout(() => s.style.opacity = 0, 1200);
  }, 500);
}

function nudgeCard(n) {
  const card = el("div", { class: "card" + (n.enabled ? "" : " off"), "data-id": n.id });
  const target = () => S.targets.find(t => t.id === n.target);
  const sw = el("label", { class: "switch", title: "On / off" },
    el("input", { type: "checkbox", "aria-label": "Enabled", onchange: e => { n.enabled = e.target.checked; card.classList.toggle("off", !n.enabled); save(); } }),
    el("span"));
  sw.querySelector("input").checked = n.enabled;
  const name = el("input", { type: "text", class: "name", "aria-label": "Name", value: n.name, oninput: e => { n.name = e.target.value; save(); } });
  const time = el("input", { type: "time", class: "time", "aria-label": "Time", value: n.time, onchange: e => { if (e.target.value) { n.time = e.target.value; save(); } } });
  const send = el("button", { "data-send": "", onclick: async () => merge(await api("POST", "/api/send?id=" + n.id)) }, "Send now");
  const del = el("button", { class: "ghost", "aria-label": "Delete " + n.name, onclick: () => {
    if (!confirm(`Delete "${n.name}"?`)) return;
    S.config.nudges = S.config.nudges.filter(x => x.id !== n.id); card.remove(); save();
  } }, "Delete");

  const days = el("div", { class: "days", role: "group", "aria-label": "Days" });
  DAY.forEach((d, i) => {
    const b = el("button", { type: "button", "aria-pressed": n.days.includes(i + 1), onclick: () => {
      const on = !n.days.includes(i + 1);
      if (!on && n.days.length === 1) return;
      n.days = on ? [...n.days, i + 1].sort() : n.days.filter(x => x !== i + 1);
      b.setAttribute("aria-pressed", on); save();
    } }, d);
    days.append(b);
  });

  // Repeat: weekly (days), once (a date), or a minute after Codex's usage resets (Codex only).
  const dateIn = el("input", { type: "date", class: "time", "aria-label": "Date", value: n.date || "", onchange: e => { if (e.target.value) { n.date = e.target.value; save(); } } });
  const codexNote = el("p", { class: "hint", "data-codex": "" });
  const repeat = el("select", { "aria-label": "Repeat", onchange: e => {
    n.repeats = e.target.value;
    if (n.repeats === "once" && !n.date) { n.date = S.today; dateIn.value = n.date; }
    const claudeTarget = n.target.startsWith("claude");
    if (n.repeats === "reset" && !["codex", "command"].includes(n.target)) { n.target = "codex"; n.chat = ""; where.value = "codex"; fillChats(); showChat(); }
    if (n.repeats === "claude-reset" && !claudeTarget && n.target !== "command") { n.target = "claude-app"; n.chat = ""; where.value = "claude-app"; fillChats(); showChat(); }
    showMode(); save();
  } }, el("option", { value: "weekly" }, "Weekly"), el("option", { value: "once" }, "Once"), el("option", { value: "reset" }, "When Codex resets"), el("option", { value: "claude-reset" }, "When Claude resets"));
  repeat.value = n.repeats || "weekly";
  const showMode = () => {
    const m = n.repeats || "weekly";
    days.hidden = m !== "weekly"; dateIn.hidden = m !== "once"; time.hidden = m === "reset";
    codexNote.hidden = m !== "reset" && m !== "claude-reset";
    showMessage();
  };
  // Codex: a new unsaved session (just starts the window), the most recent chat, or a chat by name.
  const codexChat = el("select", { "aria-label": "Codex chat", onchange: e => { n.chat = e.target.value; showChat(); save(); } });
  const fillChats = () => {
    const opts = [["", "New unsaved session (only starts the window)"], ["latest", "Most recent chat"], ...(S.codexThreads || []).map(t => [t.id, t.label])];
    if (n.chat && !opts.some(o => o[0] === n.chat)) opts.push([n.chat, "Saved chat"]);
    codexChat.replaceChildren(...opts.map(([v, l]) => el("option", { value: v }, l)));
    codexChat.value = n.chat || "";
    codexChat.dataset.count = opts.length;
  };
  const codexChatBox = el("label", {}, "Codex chat", codexChat);
  const codexChatHint = el("p", { class: "hint" }, "Continues that chat in its own folder, where it can change files, as it would in the app. It runs in the background; its reply shows in Activity.");
  const where = el("select", { onchange: e => { n.target = e.target.value; n.chat = ""; chatInput.value = ""; fillChats(); showChat(); save(); } },
    ...S.targets.filter(t => t.id !== "command" || n.target === "command").map(t => el("option", { value: t.id }, t.label)));
  where.value = n.target;
  where.disabled = n.target === "command";
  const chatInput = el("input", { type: "text", value: n.chat, oninput: e => { n.chat = e.target.value; save(); } });
  const chat = el("label", {}, "", chatInput);
  const note = el("p", { class: "hint" });
  const showChat = () => { const t = target(); codexChatBox.hidden = n.target !== "codex"; codexChatHint.hidden = n.target !== "codex" || !n.chat; note.hidden = !t?.note; note.textContent = t?.note || ""; chat.hidden = !t?.chat; chat.firstChild.textContent = t?.chat || ""; chatInput.placeholder = t?.id === "custom" ? "https://…?q={message}" : "https://…"; };
  showChat();
  const msg = el("textarea", { rows: 2, oninput: e => { n.message = e.target.value; save(); } });
  msg.readOnly = n.target === "command";
  // The message box: "Message", "Resume message" (with a fuller prompt one click away) or a command.
  const msgLabel = el("span", {}, "Message");
  const usePrompt = el("button", { type: "button", class: "ghost", onclick: () => { n.message = S.resumePrompt; msg.value = n.message; showMessage(); save(); } }, "Use detailed resume prompt");
  const showMessage = () => {
    const resume = (n.repeats || "weekly").endsWith("reset");
    msgLabel.textContent = n.target === "command" ? "Command (change it on the Mac)" : resume ? "Resume message" : "Message";
    usePrompt.hidden = !resume || n.target === "command" || n.message === S.resumePrompt;
  };
  msg.value = n.message;

  card.append(
    el("div", { class: "row" }, sw, name, dateIn, time, send, del),
    el("div", { class: "row" }, el("label", { class: "grow" }, "Repeat", repeat)),
    el("div", { class: "row" }, days),
    codexNote,
    el("label", {}, "Send to", where),
    note,
    codexChatBox,
    codexChatHint,
    chat,
    el("div", { class: "row" }, el("label", { class: "grow" }, msgLabel), usePrompt),
    msg,
    el("div", { class: "meta", "data-meta": "" }));
  fillChats();
  card.refillChats = fillChats;
  showMode();
  showChat();
  return card;
}

function render() {
  const list = document.getElementById("nudges");
  list.replaceChildren(...S.config.nudges.map(nudgeCard));
  const c = S.config;
  const browser = document.getElementById("browser");
  browser.replaceChildren(el("option", { value: "" }, `Default (${S.defaultBrowser})`), ...S.browsers.map(b => el("option", { value: b.id }, b.label)));
  browser.value = c.browser;
  document.getElementById("settle").value = c.settleSeconds;
  document.getElementById("catchup").value = c.catchUpMinutes;
  document.getElementById("restore").checked = c.restoreFocus;
  document.getElementById("lan").checked = c.allowLAN;
  document.getElementById("public").value = c.publicURL;
  document.getElementById("awakeDisplay").checked = c.awakeLetDisplaySleep;
  document.getElementById("awakeBattery").checked = c.awakeStopOnLowBattery;
  status();
}

function status() {
  const a = document.getElementById("access");
  a.className = "pill " + (S.trusted ? "ok" : "warn");
  a.replaceChildren(S.trusted ? "Accessibility allowed" :
    el("span", {}, "Needs Accessibility · ", el("a", { href: "#", onclick: async e => { e.preventDefault(); merge(await api("POST", "/api/accessibility")); } }, "allow")));
  document.getElementById("axwarn").hidden = S.trusted;
  const aw = document.getElementById("awake");
  aw.hidden = !S.awake; aw.textContent = S.awake || "";
  document.getElementById("awakeStop").hidden = !S.awake;
  if (!S.awake) document.getElementById("awakeFor").value = "0";
  const after = document.querySelector('#awakeFor option[value="-1"]');
  after.textContent = S.nextNudge ? `Until after the next nudge (${S.nextNudge})` : "Until after the next nudge (none scheduled)";
  after.disabled = !S.nextNudge;
  const s = document.getElementById("sending");
  s.hidden = !S.sending; s.textContent = "Sending " + (S.sending || "") + "…";
  for (const card of document.querySelectorAll("[data-id]")) {
    const id = card.dataset.id, n = S.config.nudges.find(x => x.id === id);
    const st = S.status[id];
    const meta = card.querySelector("[data-meta]");
    meta.textContent = st ? `Next: ${st.next} · Last: ${st.last}` : "Not saved yet";
    meta.classList.toggle("bad", !!st?.failed);
    card.querySelector("[data-send]").disabled = !!S.sending;
    const cc = card.querySelector('select[aria-label="Codex chat"]');
    if (cc && n && document.activeElement !== cc && +cc.dataset.count < (S.codexThreads || []).length + 2) card.refillChats?.();
    const cn = card.querySelector("[data-codex]");
    if (cn && n) cn.textContent = (S.status[id] || {}).reset || "";
  }
  document.getElementById("log").textContent = S.log.join("\n") || "Nothing yet.";
  const lan = document.getElementById("lanlink");
  lan.hidden = !S.lanURL;
  if (S.lanURL) lan.replaceChildren("On your phone, open ", el("code", {}, S.lanURL), " (anyone with this link can change your nudges).");
}

document.getElementById("add").onclick = () => {
  const n = { id: crypto.randomUUID(), name: "Nudge " + (S.config.nudges.length + 1), time: "06:00", days: [1,2,3,4,5,6,7], target: "claude-app", chat: "", message: "hi", enabled: true };
  S.config.nudges.push(n);
  document.getElementById("nudges").append(nudgeCard(n));
  save(); status();
};
document.getElementById("browser").onchange = e => { S.config.browser = e.target.value; save(); };
document.getElementById("settle").onchange = e => { S.config.settleSeconds = Math.max(1, +e.target.value || 4); save(); };
document.getElementById("catchup").onchange = e => { S.config.catchUpMinutes = Math.max(0, Math.round(+e.target.value || 0)); save(); };
document.getElementById("restore").onchange = e => { S.config.restoreFocus = e.target.checked; save(); };
document.getElementById("lan").onchange = e => { S.config.allowLAN = e.target.checked; save(); };
document.getElementById("awakeFor").onchange = async e => {
  merge(await api("POST", "/api/awake?minutes=" + e.target.value));
};
document.getElementById("awakeStop").onclick = async () => merge(await api("POST", "/api/awake?minutes=0"));
document.getElementById("awakeDisplay").onchange = e => { S.config.awakeLetDisplaySleep = e.target.checked; save(); };
document.getElementById("awakeBattery").onchange = e => { S.config.awakeStopOnLowBattery = e.target.checked; save(); };
document.getElementById("public").onchange = e => { S.config.publicURL = e.target.value.trim(); save(); };

(async () => {
  try { S = await api("GET", "/api/state"); render(); }
  catch { document.querySelector("main").textContent = "This page needs AI Nudge's secret link: copy it from Settings › General on the Mac."; return; }
  // Refresh the status bits (not the fields you might be typing in).
  setInterval(async () => {
    try { merge(await api("GET", "/api/state")); } catch {}
  }, 4000);
  // Pick up changes made in the Mac's settings window when you come back to this page.
  window.addEventListener("focus", async () => {
    if (saveTimer) return;
    try { S = await api("GET", "/api/state"); render(); } catch {}
  });
})();
"""#
