// Browser glue the Gleam client can't do itself: the websocket, timers,
// scrolling and focus.

export function connect(onOpen, onMessage, onClose) {
  const proto = location.protocol === "https:" ? "wss:" : "ws:";
  const ws = new WebSocket(`${proto}//${location.host}/ws`);
  ws.onopen = () => onOpen(ws);
  ws.onmessage = (event) => onMessage(event.data);
  ws.onclose = () => onClose();
}

export function send(ws, text) {
  if (ws.readyState === WebSocket.OPEN) ws.send(text);
}

export function after(ms, callback) {
  setTimeout(callback, ms);
}

// Keep the newest chronicle entry on screen (above the command bar), and
// the journal at its newest.
export function revealLatest() {
  const feed = document.querySelector(".chronicle-feed");
  const last = feed && feed.lastElementChild;
  if (last) last.scrollIntoView({ block: "nearest", behavior: "smooth" });
}

export function scrollLog() {
  const log = document.getElementById("log");
  if (log) log.scrollTop = log.scrollHeight;
}

export function focusInput() {
  // On a touch screen this would pop the keyboard up after every tap.
  if (matchMedia("(pointer: coarse)").matches) return;
  const input = document.getElementById("command");
  if (input) input.focus();
}

// A random key this browser keeps: reconnecting with the same name from the
// same browser takes over from a connection that hasn't closed yet.
export function deviceKey() {
  try {
    let key = localStorage.getItem("inkmud.device");
    if (!key) {
      key = crypto.randomUUID?.() ?? String(Math.random()).slice(2) + Date.now();
      localStorage.setItem("inkmud.device", key);
    }
    return key;
  } catch {
    return "";
  }
}

// The time now, "23:41", for the chronicle.
export function now() {
  const d = new Date();
  return `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
}

// A tiny haptic tick where the device supports it (Android); silent elsewhere.
export function buzz() {
  try {
    navigator.vibrate?.(8);
  } catch {}
}

export function focusElement(id) {
  const el = document.getElementById(id);
  if (el) el.focus();
}

export function savedName() {
  try {
    return localStorage.getItem("inkmud.name") || "";
  } catch {
    return "";
  }
}

export function forgetName() {
  try {
    localStorage.removeItem("inkmud.name");
  } catch {}
}

export function reload() {
  location.reload();
}

export function saveName(name) {
  try {
    localStorage.setItem("inkmud.name", name);
  } catch {}
}
