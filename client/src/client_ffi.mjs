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

export function scrollLog() {
  const log = document.getElementById("log");
  if (log) log.scrollTop = log.scrollHeight;
}

export function focusInput() {
  const input = document.getElementById("command");
  if (input) input.focus();
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
