// Convoy: one client, one server, and a choice of connection. Three lanes carry requests; a packet
// is lost every so often, and what happens next is the whole point —
//
//   HTTP/1.1  one request at a time, so a loss stops everything behind it;
//   HTTP/2    many streams on one connection, which still shares one loss;
//   HTTP/3    many streams, each recovering on its own.
//
// The octets each delivery costs are counted by the library itself, through the same engine the
// anatomy page uses.

(() => {
  const canvas = document.querySelector("#game");
  if (!canvas) return;

  const ctx = canvas.getContext("2d");
  const WIDTH = 760;
  const HEIGHT = 300;
  const LANES = [96, 158, 220];
  const CLIENT_X = 54;
  const SERVER_X = WIDTH - 54;
  const SPEED = 240;
  const ROUND = 45;
  const SPAWN = 0.85;
  const LOSS_EVERY = 2.8;
  const STALL = 0.85;

  let palette = {};
  const readPalette = () => {
    const style = getComputedStyle(document.documentElement);
    palette = {
      paper: style.getPropertyValue("--paper").trim() || "#f7f5f0",
      ink: style.getPropertyValue("--ink").trim() || "#14110d",
      dim: style.getPropertyValue("--ink-3").trim() || "#8a8478",
      rule: style.getPropertyValue("--rule").trim() || "#ded8cb",
      silk: style.getPropertyValue("--silk").trim() || "#a83a2c",
      mono: getComputedStyle(document.body).getPropertyValue("--mono").trim() || "monospace",
    };
  };
  readPalette();
  new MutationObserver(readPalette).observe(document.documentElement, {
    attributes: true,
    attributeFilter: ["data-theme"],
  });

  const transports = {
    h1: { name: "HTTP/1.1", lanes: 1, shareLoss: true, note: "one request at a time; a loss stops the line" },
    h2: { name: "HTTP/2", lanes: 3, shareLoss: true, note: "many streams, one connection: a loss stops them all" },
    h3: { name: "HTTP/3", lanes: 3, shareLoss: false, note: "many streams, each recovers on its own" },
  };

  let state = {};
  let costs = { h1: 74, h2: 87 };

  const reset = () => {
    state = {
      transport: "h1",
      running: false,
      over: false,
      time: ROUND,
      spawnIn: 0.4,
      lossIn: LOSS_EVERY,
      pending: [],
      moving: [],
      delivered: 0,
      dropped: 0,
      bytes: 0,
      stall: LANES.map(() => 0),
      flash: LANES.map(() => 0),
      message: "",
    };
    paintScore();
    paintNote();
  };

  const paintScore = () => {
    const score = document.querySelector("[data-score]");
    if (!score) return;
    score.innerHTML =
      `<b>${state.delivered}</b> delivered · <b>${state.dropped}</b> lost · ` +
      `<b>${(state.time).toFixed(0)}s</b> left · <b>${state.bytes}</b> octets`;
  };

  const paintNote = () => {
    const note = document.querySelector("[data-note]");
    if (note) note.textContent = transports[state.transport].note;
  };

  const choose = (key) => {
    if (!transports[key]) return;
    state.transport = key;
    // Whatever is in flight keeps its lane; a switch only changes where new requests go.
    for (const button of document.querySelectorAll("[data-transport]")) {
      button.classList.toggle("solid", button.dataset.transport === key);
    }
    paintNote();
  };

  const start = () => {
    reset();
    state.running = true;
    last = performance.now();
    requestAnimationFrame(frame);
  };

  let last = 0;

  const frame = (now) => {
    const dt = Math.min(0.05, (now - last) / 1000);
    last = now;
    if (state.running) step(dt);
    draw();
    if (state.running) requestAnimationFrame(frame);
  };

  const step = (dt) => {
    state.time = Math.max(0, state.time - dt);
    if (state.time === 0 && state.running) {
      state.running = false;
      state.over = true;
      state.message = "the clock ran out";
      paintScore();
      return;
    }
    state.spawnIn -= dt;
    if (state.spawnIn <= 0) {
      state.spawnIn = SPAWN;
      if (state.pending.length < 10) state.pending.push(true);
      else state.dropped += 1;
    }
    state.lossIn -= dt;
    if (state.lossIn <= 0) {
      state.lossIn = LOSS_EVERY;
      // The counter says what happened to the traffic: a packet lost is a request lost.
      state.dropped += 1;
      const lanes = transports[state.transport].lanes;
      const lane = Math.floor(Math.random() * lanes);
      if (transports[state.transport].shareLoss) {
        for (let i = 0; i < lanes; i++) {
          state.stall[i] = STALL;
          state.flash[i] = 0.5;
        }
      } else {
        state.stall[lane] = STALL;
        state.flash[lane] = 0.5;
      }
    }
    for (let i = 0; i < LANES.length; i++) {
      state.stall[i] = Math.max(0, state.stall[i] - dt);
      state.flash[i] = Math.max(0, state.flash[i] - dt);
    }
    const lanes = transports[state.transport].lanes;
    for (let lane = 0; lane < lanes; lane++) {
      if (state.pending.length === 0) break;
      if (state.moving.some((packet) => packet.lane === lane)) continue;
      if (state.stall[lane] > 0) continue;
      state.pending.pop();
      state.moving.push({ lane, x: CLIENT_X });
    }
    for (const packet of state.moving) {
      if (state.stall[packet.lane] > 0) continue;
      packet.x += SPEED * dt;
      if (packet.x >= SERVER_X) {
        packet.done = true;
        state.delivered += 1;
        state.bytes += state.transport === "h1" ? costs.h1 : costs.h2;
      }
    }
    state.moving = state.moving.filter((packet) => !packet.done);
    paintScore();
  };

  const draw = () => {
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    const scale = canvas.width / WIDTH;
    ctx.scale(scale, scale);
    ctx.clearRect(0, 0, WIDTH, HEIGHT);

    ctx.font = `11px ${palette.mono}`;
    ctx.textBaseline = "middle";

    // The two ends.
    ctx.strokeStyle = palette.rule;
    ctx.lineWidth = 1;
    const used = transports[state.transport].lanes;
    for (let i = 0; i < LANES.length; i++) {
      // A lane the transport does not use is drawn, but faintly: the shape of the choice.
      ctx.globalAlpha = i < used ? 1 : 0.28;
      ctx.beginPath();
      ctx.moveTo(CLIENT_X, LANES[i]);
      ctx.lineTo(SERVER_X, LANES[i]);
      ctx.stroke();
    }
    ctx.globalAlpha = 1;
    ctx.beginPath();
    ctx.moveTo(CLIENT_X, LANES[0] - 26);
    ctx.lineTo(CLIENT_X, LANES[2] + 26);
    ctx.moveTo(SERVER_X, LANES[0] - 26);
    ctx.lineTo(SERVER_X, LANES[2] + 26);
    ctx.stroke();

    ctx.fillStyle = palette.dim;
    ctx.textAlign = "center";
    ctx.fillText("client", CLIENT_X, LANES[0] - 40);
    ctx.fillText("server", SERVER_X, LANES[0] - 40);

    // What each lane carries, so the shape of the choice is legible before the first run.
    const transport = transports[state.transport];
    ctx.textAlign = "left";
    for (let i = 0; i < transport.lanes; i++) {
      ctx.fillText(transport.lanes === 1 ? "one connection" : `stream ${i + 1}`, CLIENT_X + 10, LANES[i] - 11);
    }

    // Requests waiting at the client.
    for (let i = 0; i < state.pending.length; i++) {
      ctx.beginPath();
      ctx.arc(CLIENT_X - 16 - i * 9, LANES[0] - 8, 2.4, 0, Math.PI * 2);
      ctx.fillStyle = palette.dim;
      ctx.fill();
    }

    // Packets in flight, and a loss flash where one was.
    for (const packet of state.moving) {
      const y = LANES[packet.lane];
      ctx.beginPath();
      ctx.arc(packet.x, y, 3.2, 0, Math.PI * 2);
      ctx.fillStyle = palette.ink;
      ctx.fill();
    }
    for (let i = 0; i < state.flash.length; i++) {
      if (state.flash[i] <= 0) continue;
      const x = (CLIENT_X + SERVER_X) / 2;
      const y = LANES[i];
      ctx.globalAlpha = Math.min(1, state.flash[i] * 2);
      ctx.strokeStyle = palette.silk;
      ctx.beginPath();
      ctx.moveTo(x - 3, y - 3);
      ctx.lineTo(x + 3, y + 3);
      ctx.moveTo(x + 3, y - 3);
      ctx.lineTo(x - 3, y + 3);
      ctx.stroke();
      // The thread is cut where the packet was: a gap in the lane, not a second lane.
      ctx.globalAlpha = 1;
      ctx.fillStyle = palette.paper;
      ctx.fillRect(x - 9, y - 1, 18, 2);
      ctx.globalAlpha = Math.min(1, state.flash[i] * 2);
      ctx.beginPath();
      ctx.moveTo(x - 3, y - 3);
      ctx.lineTo(x + 3, y + 3);
      ctx.moveTo(x + 3, y - 3);
      ctx.lineTo(x - 3, y + 3);
      ctx.stroke();
      ctx.globalAlpha = 1;
    }

    // A stalled connection says so once, however many lanes it holds up.
    if (state.stall.some((left) => left > 0)) {
      ctx.fillStyle = palette.silk;
      ctx.textAlign = "center";
      ctx.fillText(
        transports[state.transport].shareLoss ? "lost — the connection waits" : "lost — this stream waits",
        (CLIENT_X + SERVER_X) / 2,
        LANES[0] - 24,
      );
    }

    ctx.textAlign = "center";
    if (!state.running && !state.over) {
      ctx.fillStyle = palette.dim;
      ctx.font = `12px ${palette.mono}`;
      ctx.fillText(
        "press Run — ten requests, and a packet lost every few seconds",
        WIDTH / 2,
        LANES[2] + 36,
      );
    }

    if (state.over) {
      ctx.fillStyle = palette.ink;
      ctx.font = `13px ${palette.mono}`;
      ctx.fillText(
        `${state.message} — ${state.delivered} delivered over ${transports[state.transport].name}`,
        WIDTH / 2,
        LANES[2] + 28,
      );
      ctx.fillStyle = palette.dim;
      ctx.font = `11px ${palette.mono}`;
      ctx.fillText("press Run again, or pick another transport", WIDTH / 2, LANES[2] + 50);
    }
  };

  const fit = () => {
    const ratio = Math.min(2, devicePixelRatio || 1);
    canvas.width = WIDTH * ratio;
    canvas.height = HEIGHT * ratio;
    canvas.style.aspectRatio = `${WIDTH} / ${HEIGHT}`;
    draw();
  };

  for (const button of document.querySelectorAll("[data-transport]")) {
    button.addEventListener("click", () => {
      choose(button.dataset.transport);
    });
  }
  document.querySelector("[data-play]")?.addEventListener("click", start);
  addEventListener("keydown", (event) => {
    if (event.target.matches("input, textarea, select")) return;
    if (event.key === "1") choose("h1");
    if (event.key === "2") choose("h2");
    if (event.key === "3") choose("h3");
    if (event.key === " ") {
      event.preventDefault();
      start();
    }
  });
  addEventListener("resize", fit, { passive: true });

  // The octets a delivery costs come from the library, so the numbers on the page are its own.
  import("../engine/moonfetch.js")
    .then((module) => {
      const parsed = JSON.parse(module.costs("https://example.com/a?b=1"));
      if (!parsed.error) costs = { h1: parsed.h1, h2: parsed.h2 };
    })
    .catch(() => {});

  reset();
  fit();
})();
