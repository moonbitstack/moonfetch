// The anatomy page: a request goes in, the octets it becomes come out. Everything shown is
// computed by the library, built to JavaScript beside this file; nothing here re-encodes a
// request to make the picture.

const engine = import("../engine/moonfetch.js");

const form = document.querySelector("[data-form]");
const verbField = document.querySelector("[data-verb]");
const urlField = document.querySelector("[data-url]");
const headersField = document.querySelector("[data-headers]");
const bodyField = document.querySelector("[data-body]");
const bytesOut = document.querySelector("[data-h1]");
const h1Size = document.querySelector("[data-h1-size]");
const framesOut = document.querySelector("[data-h2]");
const h2Size = document.querySelector("[data-h2-size]");
const answer = document.querySelector("[data-answer]");
const sendButton = document.querySelector("[data-send]");

const esc = (text) =>
  String(text).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

/** Headers typed as `name: value`, one to a line, as a page sends them to the library. */
function headerPairs() {
  const rows = [];
  for (const line of headersField.value.split("\n")) {
    const at = line.indexOf(":");
    if (at <= 0) continue;
    rows.push([line.slice(0, at).trim(), line.slice(at + 1).trim()]);
  }
  return rows;
}

function paintHead(text) {
  return text
    .split("\r\n")
    .map((line, at) => {
      if (at === 0) return `<span class="r">${esc(line)}</span>`;
      if (line === "") return "";
      const colon = line.indexOf(":");
      if (colon < 0) return esc(line);
      return `<span class="h">${esc(line.slice(0, colon))}</span>:<span class="b">${esc(line.slice(colon + 1))}</span>`;
    })
    .join("\n");
}

function paintFrames(pieces) {
  return pieces
    .map((piece) => {
      const [name, ...flags] = piece.label.split(" + ");
      const rest = flags.length ? ` <s>+ ${esc(flags.join(" + "))}</s>` : "";
      return `<div class="frame">
        <div class="name"><b>${esc(name)}</b>${rest}</div>
        <div class="size">${piece.size} B</div>
        <div class="hex">${esc(piece.hex.replace(/(..)/g, "$1 ").trim())}</div>
      </div>`;
    })
    .join("");
}

async function redraw() {
  const module = await engine;
  let parsed;
  try {
    parsed = JSON.parse(
      module.preview(verbField.value, urlField.value.trim(), JSON.stringify(headerPairs()), bodyField.value),
    );
  } catch (error) {
    bytesOut.innerHTML = `<span class="h">${esc(error.message)}</span>`;
    framesOut.innerHTML = "";
    return;
  }
  if (parsed.error) {
    bytesOut.innerHTML = `<span class="h">${esc(parsed.error)}</span>`;
    framesOut.innerHTML = "";
    h1Size.textContent = "";
    h2Size.textContent = "";
    return;
  }
  const head = parsed.h1.pieces[0];
  const rest = parsed.h1.pieces.slice(1);
  bytesOut.innerHTML =
    paintHead(head.text) +
    rest
      .map((piece) => `\n\n<span class="h">${esc(piece.label)}</span>\n<span class="b">${esc(piece.text)}</span>`)
      .join("");
  const total = parsed.h1.pieces.reduce((sum, piece) => sum + piece.size, 0);
  h1Size.textContent = `${total} octets`;
  framesOut.innerHTML = paintFrames(parsed.h2.pieces);
  const over = parsed.h2.pieces.reduce((sum, piece) => sum + piece.size, 0);
  h2Size.textContent = `${parsed.h2.pieces.length} pieces · ${over} octets`;
}

for (const field of [verbField, urlField, headersField, bodyField]) {
  field.addEventListener("input", redraw);
  field.addEventListener("change", redraw);
}

sendButton?.addEventListener("click", async () => {
  const module = await engine;
  sendButton.disabled = true;
  answer.innerHTML = `<span class="k">sending…</span>`;
  try {
    const raw = await module.send(
      verbField.value,
      urlField.value.trim(),
      JSON.stringify(headerPairs()),
      bodyField.value,
    );
    const reply = JSON.parse(raw);
    if (reply.error) {
      answer.innerHTML = `<span class="k">refused</span> ${esc(reply.error)}`;
    } else {
      const total = reply.headers.length;
      const fields = reply.headers
        .slice(0, 12)
        .map(([name, value]) => `<span class="k">${esc(name)}</span>: ${esc(value)}`)
        .join("\n");
      const text = reply.body.length > 700 ? reply.body.slice(0, 700) + "\n…" : reply.body;
      answer.innerHTML =
        `<span class="status">${reply.status}</span> ${esc(reply.reason)} · ${reply.ms.toFixed(0)} ms · ${reply.body.length} octets\n` +
        `<span class="k">${total} fields</span>\n${fields}\n\n${esc(text)}`;
    }
  } catch (error) {
    answer.innerHTML = `<span class="k">the request did not finish</span> ${esc(error.message)}`;
  } finally {
    sendButton.disabled = false;
  }
});

redraw();
