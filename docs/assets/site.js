// moonfetch — the page behaves like a sheet of drafting linen: a thread down the left, a bead
// where the reader is, and a web that spins itself once.

(() => {
  const root = document.documentElement;

  /* ------------------------------------------------------------ theme */

  const KEY = "moonfetch-theme";
  const saved = (() => {
    try {
      return localStorage.getItem(KEY);
    } catch {
      return null;
    }
  })();
  if (saved === "light" || saved === "dark") root.dataset.theme = saved;

  const button = document.querySelector("[data-theme-toggle]");
  const current = () =>
    root.dataset.theme || (matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light");
  const label = () => (current() === "dark" ? "Switch to the light sheet" : "Switch to the dark sheet");

  if (button) {
    button.setAttribute("aria-label", label());
    button.title = label();
    button.addEventListener("click", () => {
      const next = current() === "dark" ? "light" : "dark";
      root.dataset.theme = next;
      try {
        localStorage.setItem(KEY, next);
      } catch {
        /* a page that cannot remember still switches */
      }
      button.setAttribute("aria-label", label());
      button.title = label();
    });
  }

  /* ------------------------------------------------------------ the scroll bar at the top */

  const mark = () => root.classList.toggle("at-top", scrollY <= 0);
  addEventListener("scroll", mark, { passive: true });
  mark();

  /* ------------------------------------------------------------ the bead on the thread */

  const page = document.querySelector("main.page");
  const bead = document.createElement("i");
  bead.className = "bead";
  bead.setAttribute("aria-hidden", "true");
  if (page) page.append(bead);

  let queued = false;
  const place = () => {
    queued = false;
    if (!page || !bead) return;
    const top = page.getBoundingClientRect().top;
    // The bead sits where the reader's eye is, in the page's own coordinates, so it stays on the
    // thread whatever the width.
    bead.style.top = `${innerHeight * 0.42 - top}px`;
  };
  addEventListener(
    "scroll",
    () => {
      if (queued) return;
      queued = true;
      requestAnimationFrame(place);
    },
    { passive: true },
  );
  addEventListener("resize", place, { passive: true });
  place();

  /* ------------------------------------------------------------ sections light their node */

  const stops = [...document.querySelectorAll(".stop")];
  if (stops.length) {
    const seen = new IntersectionObserver(
      (entries) => {
        for (const entry of entries) entry.target.classList.toggle("lit", entry.isIntersecting);
      },
      { rootMargin: "-18% 0px -52% 0px" },
    );
    for (const stop of stops) seen.observe(stop);
  }

  const risers = [...document.querySelectorAll(".rise")];
  if (risers.length && !matchMedia("(prefers-reduced-motion: reduce)").matches) {
    const rising = new IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          if (!entry.isIntersecting) continue;
          entry.target.classList.add("in");
          rising.unobserve(entry.target);
        }
      },
      { rootMargin: "0px 0px -8% 0px" },
    );
    for (const node of risers) rising.observe(node);
  } else {
    for (const node of risers) node.classList.add("in");
  }

  /* ------------------------------------------------------------ the web */

  const web = document.querySelector("[data-web]");
  if (web) {
    const spokes = 12;
    const rings = 8;
    const size = 640;
    const centre = size / 2;
    const rand = (() => {
      let seed = 20261108;
      return () => {
        seed = (seed * 1103515245 + 12345) & 0x7fffffff;
        return seed / 0x7fffffff;
      };
    })();

    // Each spoke leaves the centre at its own angle, so the web reads as spun rather than printed.
    const angles = Array.from({ length: spokes }, (_, i) => {
      const base = (i / spokes) * Math.PI * 2 - Math.PI / 2;
      return base + (rand() - 0.5) * 0.05;
    });
    const outer = 292;
    const points = [];
    for (let i = 0; i < spokes; i++) {
      const reach = outer * (0.94 + rand() * 0.1);
      points.push([centre + Math.cos(angles[i]) * reach, centre + Math.sin(angles[i]) * reach]);
    }

    const parts = [];
    for (let i = 0; i < spokes; i++) {
      const [x, y] = points[i];
      parts.push(`<path d="M${centre} ${centre}L${x.toFixed(1)} ${y.toFixed(1)}"/>`);
    }

    for (let ring = 1; ring <= rings; ring++) {
      const radius = outer * Math.pow(ring / rings, 1.1);
      // The thread sags between the spokes it passes, which is what a thread under its own
      // weight does: every other point sits a little nearer the centre.
      const d = [];
      for (let i = 0; i < spokes * 2; i++) {
        const at = i >> 1;
        const angle = angles[at];
        const next = angles[(at + 1) % spokes] + (at + 1 === spokes ? Math.PI * 2 : 0);
        const mid = (angle + next) / 2;
        const reach = radius * (i % 2 === 0 ? 1 : 0.955);
        const x = centre + Math.cos(i % 2 === 0 ? angle : mid) * reach;
        const y = centre + Math.sin(i % 2 === 0 ? angle : mid) * reach;
        d.push(`${i === 0 ? "M" : "L"}${x.toFixed(1)} ${y.toFixed(1)}`);
      }
      parts.push(`<path d="${d.join("")}Z"/>`);
    }

    // One strand carries the accent: the one the spider is on.
    const accent = points[3];
    parts.push(
      `<path d="M${centre} ${centre}L${accent[0].toFixed(1)} ${accent[1].toFixed(1)}" stroke="var(--silk-soft)" stroke-width="1.2"/>`,
    );
    for (const [x, y] of points) {
      parts.push(`<circle class="anchor" cx="${x.toFixed(1)}" cy="${y.toFixed(1)}" r="2"/>`);
    }
    web.innerHTML = parts.join("");

    if (!matchMedia("(prefers-reduced-motion: reduce)").matches) {
      const hero = document.querySelector(".hero");
      hero?.addEventListener("pointermove", (event) => {
        const box = hero.getBoundingClientRect();
        const dx = (event.clientX - box.width / 2) / box.width;
        const dy = (event.clientY - box.height / 2) / box.height;
        web.style.transform = `translate(${(dx * 10).toFixed(1)}px, ${(dy * 8).toFixed(1)}px)`;
      });
      hero?.addEventListener("pointerleave", () => {
        web.style.transform = "";
      });

      let fading = false;
      const fade = () => {
        fading = false;
        const y = Math.min(1, scrollY / (innerHeight * 0.75));
        web.style.opacity = String(0.9 - y * 0.62);
      };
      addEventListener(
        "scroll",
        () => {
          if (fading) return;
          fading = true;
          requestAnimationFrame(fade);
        },
        { passive: true },
      );
    }
  }

  /* ------------------------------------------------------------ MoonBit blocks */

  const KEYWORDS =
    /\b(async|fn|let|mut|match|if|else|guard|for|while|loop|return|raise|try|catch|noraise|defer|errdefer|pub|priv|struct|enum|suberror|trait|impl|extend|type|test|true|false|None|Some|break|continue|abort|is|as|self|in)\b/g;

  const paint = (source) => {
    // Strings, then comments, then keywords — each step escapes what it wraps, so nothing is
    // matched twice.
    const slots = [];
    const keep = (html) => `\u0000${slots.push(html) - 1}\u0000`;
    let text = source.replace(/"(?:[^"\\\n]|\\.)*"/g, (match) => keep(`<span class="s">${esc(match)}</span>`));
    text = text.replace(/\/\/[^\n]*/g, (match) => keep(`<span class="c">${esc(match)}</span>`));
    text = esc(text);
    text = text.replace(KEYWORDS, '<span class="k">$1</span>');
    return text.replace(/\u0000(\d+)\u0000/g, (_, at) => slots[Number(at)]);
  };

  const esc = (text) =>
    text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

  for (const block of document.querySelectorAll("pre.code > code")) {
    if (block.dataset.painted) continue;
    block.dataset.painted = "1";
    block.innerHTML = paint(block.textContent);
  }
})();
