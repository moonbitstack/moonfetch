// Every MoonBit block on the site becomes a sheet: a label, a copy button, a numbered margin,
// and the tokens inked. The source in the HTML stays plain text, so what the snippet checker
// compiles is exactly what a reader copies.

(() => {
  const KEYWORDS = new Set([
    "abort", "as", "async", "break", "catch", "continue", "defer", "else", "enum", "errdefer",
    "extend", "false", "fn", "for", "guard", "if", "impl", "in", "is", "let", "loop", "match",
    "mut", "noraise", "priv", "pub", "raise", "return", "self", "struct", "suberror", "test",
    "trait", "true", "try", "type", "while", "with",
  ]);

  // One alternation, longest sense first: a comment before a keyword, a string before a number.
  // Strings cannot cross a newline in MoonBit, so a line at a time is safe.
  const TOKEN =
    /(\/\/[^\n]*)|("(?:[^"\\\n]|\\.)*")|(b?'(?:[^'\\\n]|\\.)')|(#[a-z]+\((?:[^()]|\([^()]*\))*\))|(@[a-z_][\w]*(?:\.[a-z_][\w]*)*)|(::[A-Z][\w]*)|(\b\d[\d_]*(?:\.\d+)?\b)|(\b[A-Z][\w]*\b)|(\b[a-z_]\w*\b)/g;

  const esc = (text) =>
    text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

  const ink = (line) => {
    let out = "";
    let at = 0;
    TOKEN.lastIndex = 0;
    for (let m = TOKEN.exec(line); m; m = TOKEN.exec(line)) {
      out += esc(line.slice(at, m.index));
      const text = esc(m[0]);
      let kind;
      if (m[1]) kind = "c";
      else if (m[2] || m[3]) kind = "s";
      else if (m[4]) kind = "a";
      else if (m[5]) kind = "m";
      else if (m[6]) kind = "t";
      else if (m[7]) kind = "n";
      else if (m[8]) kind = "t";
      else if (m[9] && KEYWORDS.has(m[0])) kind = "k";
      else {
        out += text;
        at = m.index + m[0].length;
        continue;
      }
      out += `<span class="tok-${kind}">${text}</span>`;
      at = m.index + m[0].length;
    }
    return out + esc(line.slice(at));
  };

  const LABELS = { mbt: "MoonBit", moonbit: "MoonBit", sh: "shell", bash: "shell", json: "JSON" };

  const sheets = (pre) => {
    const source = pre.textContent.replace(/\n$/, "");
    const shell = !pre.dataset.lang && /^\s*moon\s/.test(source);
    const lang = shell ? "shell" : pre.dataset.lang || "moonbit";

    const shellBlock = document.createElement("div");
    shellBlock.className = "snippet";
    if (pre.dataset.native !== undefined) shellBlock.dataset.native = "";

    const bar = document.createElement("div");
    bar.className = "snippet-bar";

    const label = document.createElement("span");
    label.className = "snippet-label";
    label.textContent = pre.dataset.file || LABELS[lang] || lang;
    bar.append(label);

    if (pre.dataset.native !== undefined) {
      const chip = document.createElement("span");
      chip.className = "snippet-chip";
      chip.textContent = "native · wasm";
      chip.title = "This program does not compile for the browser: a page owns its cookies and its connections.";
      bar.append(chip);
    }

    const copy = document.createElement("button");
    copy.className = "snippet-copy";
    copy.type = "button";
    copy.textContent = "copy";
    copy.setAttribute("aria-label", "Copy this block");
    copy.addEventListener("click", async () => {
      try {
        await navigator.clipboard.writeText(source);
        copy.textContent = "copied";
        copy.classList.add("done");
      } catch {
        copy.textContent = "select it";
      }
      setTimeout(() => {
        copy.textContent = "copy";
        copy.classList.remove("done");
      }, 1400);
    });
    bar.append(copy);

    const body = document.createElement("pre");
    body.className = "snippet-body";

    const lines = source.split("\n");
    if (shell) {
      const prompt = document.createElement("span");
      prompt.className = "tok-p";
      prompt.textContent = "$ ";
      const command = document.createElement("span");
      command.innerHTML = lines.map(ink).join("\n");
      prompt.append(command);
      body.append(prompt);
    } else {
      // Two lines need no margin: a gutter would be a column of numbers with nothing to say.
      const numbered = lines.length > 2;
      if (!numbered) body.classList.add("plain");
      body.innerHTML = lines
        .map((line, at) => {
          const gutter = numbered
            ? `<i aria-hidden="true">${String(at + 1).padStart(2, "0")}</i>`
            : "";
          return `<span class="snippet-line">${gutter}<span class="snippet-tx">${ink(line) || " "}</span></span>`;
        })
        .join("");
    }

    shellBlock.append(bar, body);
    pre.replaceWith(shellBlock);
  };

  for (const pre of document.querySelectorAll("pre.code")) sheets(pre);
})();
