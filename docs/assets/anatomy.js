// The anatomy bench: a request goes in, the octets it becomes come out. Everything shown is
// computed by the library, built to JavaScript beside this file; nothing here re-encodes a
// request to make the picture.

const engine = import("../engine/moonfetch.js");

const verbField = document.querySelector("[data-verb]");
const urlField = document.querySelector("[data-url]");
const headersField = document.querySelector("[data-headers]");
const bodyField = document.querySelector("[data-body]");
const bytesOut = document.querySelector("[data-h1]");
const h1Size = document.querySelector("[data-h1-size]");
const framesOut = document.querySelector("[data-h2]");
const h2Size = document.querySelector("[data-h2-size]");
const h1Cost = document.querySelector("[data-h1-cost]");
const h2Cost = document.querySelector("[data-h2-cost]");
const gaugeH1 = document.querySelector("[data-gauge-h1]");
const gaugeH2 = document.querySelector("[data-gauge-h2]");
const replyState = document.querySelector("[data-reply-state]");
const replyMeta = document.querySelector("[data-reply-meta]");
const replyStale = document.querySelector("[data-reply-stale]");
const answer = document.querySelector("[data-answer]");
const sendButton = document.querySelector("[data-send]");

const CONTROL = new Set(["SETTINGS", "PING", "WINDOW_UPDATE", "GOAWAY", "RST_STREAM", "PRIORITY"]);

const esc = (text) =>
  String(text).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

/** Fields typed as `name: value`, one to a line, as a page hands them to the library. */
function headerPairs() {
  const rows = [];
  for (const line of headersField.value.split("\n")) {
    const at = line.indexOf(":");
    if (at <= 0) continue;
    rows.push([line.slice(0, at).trim(), line.slice(at + 1).trim()]);
  }
  return rows;
}

/** The head, inked: the request line carries the silk, the names recede, the values hold. */
function paintHead(text) {
  return text
    .split("\r\n")
    .map((line, at) => {
      if (at === 0) return `<span class="r">${esc(line)}</span>`;
      if (line === "") return "";
      const colon = line.indexOf(":");
      if (colon < 0) return esc(line);
      return `<span class="h">${esc(line.slice(0, colon))}</span>:<span class="b">${esc(
        line.slice(colon + 1),
      )}</span>`;
    })
    .join("\n");
}

/** Octets are not always text: a body with control codes is shown as it goes out. */
function paintBody(piece) {
  const text = piece.text;
  const readable = !/[\u0000-\u0008\u000b\u000c\u000e-\u001f]/.test(text);
  const body = readable ? esc(text.replace(/\r\n/g, "\n")) : esc(piece.hex.replace(/(..)/g, "$1 ").trim());
  return `<span class="rule">body · ${piece.size} octets</span><span class="b">${body}</span>`;
}

/** A frame: its name, the flags it set, its length, and as much of its octets as fits. */
function paintFrames(pieces) {
  return pieces
    .map((piece) => {
      const [name, ...flags] = piece.label.split(" + ");
      const kind = name.startsWith("DATA") ? "data" : CONTROL.has(name) ? "control" : "";
      const flagsHtml = flags.map((flag) => `<s>${esc(flag)}</s>`).join("");
      const shown = 30;
      const cut = piece.hex.length > shown * 2;
      const hex = (cut ? piece.hex.slice(0, shown * 2) : piece.hex).replace(/(..)/g, "$1 ").trim();
      const rest = cut ? ` … ${piece.size - shown} more` : "";
      return `<div class="frame ${kind}">
        <div class="frame-name"><b>${esc(name)}</b>${flagsHtml}</div>
        <div class="frame-size">${piece.size} B</div>
        <code class="frame-hex">${esc(hex)}${esc(rest)}</code>
      </div>`;
    })
    .join("");
}

function clear() {
  bytesOut.innerHTML = "";
  framesOut.innerHTML = "";
  h1Size.textContent = "";
  h2Size.textContent = "";
  h1Cost.textContent = "—";
  h2Cost.textContent = "—";
  gaugeH1.style.setProperty("--fill", "0%");
  gaugeH2.style.setProperty("--fill", "0%");
}

function fail(why) {
  clear();
  bytesOut.innerHTML = `<span class="h">${esc(why)}</span>`;
  framesOut.innerHTML = `<div class="pane-empty">no request to write</div>`;
}

let pending = 0;
let timer = 0;

// The request the answer belongs to, so that an edited field does not leave an old answer
// looking like the answer to what is now on screen.
let answered = null;
const request = () =>
  [verbField.value, urlField.value.trim(), JSON.stringify(headerPairs()), bodyField.value].join("\u0000");

async function redraw() {
  const mine = ++pending;
  let parsed;
  try {
    const module = await engine;
    parsed = JSON.parse(
      module.preview(
        verbField.value,
        urlField.value.trim(),
        JSON.stringify(headerPairs()),
        bodyField.value,
      ),
    );
  } catch (error) {
    if (mine === pending) fail(error.message);
    return;
  }
  if (mine !== pending) return;
  if (parsed.error) {
    fail(parsed.error);
    return;
  }
  if (replyStale) replyStale.hidden = answered === null || answered === request();

  const [head, ...rest] = parsed.h1.pieces;
  bytesOut.innerHTML =
    paintHead(head.text) +
    rest.map((piece) => "\n" + paintBody(piece)).join("");
  const one = parsed.h1.pieces.reduce((sum, piece) => sum + piece.size, 0);
  h1Size.textContent = `${one} octets`;

  framesOut.innerHTML = paintFrames(parsed.h2.pieces);
  const two = parsed.h2.pieces.reduce((sum, piece) => sum + piece.size, 0);
  h2Size.textContent = `${parsed.h2.pieces.length} frames · ${two} octets`;

  // The two weights, to scale against each other: at a glance, not a paragraph.
  const top = Math.max(one, two, 1);
  h1Cost.textContent = `${one} B`;
  h2Cost.textContent = `${two} B`;
  gaugeH1.style.setProperty("--fill", `${Math.max(6, (one / top) * 100)}%`);
  gaugeH2.style.setProperty("--fill", `${Math.max(6, (two / top) * 100)}%`);
}

for (const field of [verbField, urlField, headersField, bodyField]) {
  field.addEventListener("input", () => {
    clearTimeout(timer);
    timer = setTimeout(redraw, 90);
  });
  field.addEventListener("change", redraw);
}

/* ------------------------------------------------------------ send it for real */

async function send() {
  const module = await engine;
  sendButton.disabled = true;
  replyState.textContent = "sending…";
  replyState.className = "";
  replyMeta.textContent = "";
  answer.innerHTML = `<span class="k">${esc(verbField.value)} ${esc(urlField.value.trim())}</span>`;
  answered = request();
  if (replyStale) replyStale.hidden = true;
  try {
    const raw = await module.send(
      verbField.value,
      urlField.value.trim(),
      JSON.stringify(headerPairs()),
      bodyField.value,
    );
    const reply = JSON.parse(raw);
    if (reply.error) {
      replyState.textContent = "refused";
      replyState.className = "status";
      replyMeta.textContent = "";
      answer.textContent = reply.error;
      return;
    }
    replyState.textContent = `${reply.status} ${reply.reason}`;
    replyState.className = reply.status < 400 ? "status ok" : "status";
    replyMeta.textContent = `${reply.ms.toFixed(0)} ms · ${reply.body.length} octets · ${reply.headers.length} fields`;
    const fields = reply.headers
      .slice(0, 14)
      .map(([name, value]) => `<span class="k">${esc(name)}</span>: ${esc(value)}`)
      .join("\n");
    const text = reply.body.length > 1200 ? reply.body.slice(0, 1200) + "\n…" : reply.body;
    answer.innerHTML = `${fields}\n\n<span class="body">${esc(text)}</span>`;
  } catch (error) {
    replyState.textContent = "did not finish";
    replyState.className = "status";
    answer.textContent = error.message;
  } finally {
    sendButton.disabled = false;
  }
}

sendButton?.addEventListener("click", send);

// A request is written with the keyboard, so it is sent with it.
document.addEventListener("keydown", (event) => {
  if ((event.metaKey || event.ctrlKey) && event.key === "Enter") {
    event.preventDefault();
    if (!sendButton?.disabled) send();
  }
});

/* ------------------------------------------------------------ three requests worth typing */

const PRESETS = {
  json: {
    verb: "POST",
    url: "https://httpbin.org/anything",
    headers: "content-type: application/json\naccept: application/json",
    body: '{"name":"moonfetch","versions":["h1","h2","h3"]}',
  },
  form: {
    verb: "POST",
    url: "https://httpbin.org/anything",
    headers: "content-type: application/x-www-form-urlencoded",
    body: "user=moon&pass=tide",
  },
  bulk: {
    verb: "PUT",
    url: "https://httpbin.org/anything",
    headers: "content-type: application/octet-stream",
    body: Array.from({ length: 128 }, (_, at) => `line ${String(at + 1).padStart(3, "0")} of a body that is too big for one frame`).join("\n"),
  },
};

for (const chip of document.querySelectorAll("[data-preset]")) {
  chip.addEventListener("click", () => {
    const preset = PRESETS[chip.dataset.preset];
    if (!preset) return;
    verbField.value = preset.verb;
    urlField.value = preset.url;
    headersField.value = preset.headers;
    bodyField.value = preset.body;
    redraw();
  });
}

redraw();
