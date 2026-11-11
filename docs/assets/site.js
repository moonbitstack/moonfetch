// moonfetch — the page behaves like a sheet of drafting linen: a thread down the left, a bead
// where the reader is, and a web that spins itself once.

(() => {
  const root = document.documentElement;

  /* ------------------------------------------------------------ theme */

  // `theme.js` has already put a stored choice on the document, before the sheet was painted.
  // What is left is the switch, its label, and keeping a page that is already open in step with
  // a choice made on another one.
  const KEY = "moonfetch-theme";
  const button = document.querySelector("[data-theme-toggle]");
  const system = () => (matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light");
  const current = () => root.dataset.theme || system();
  const label = () => (current() === "dark" ? "Switch to the light sheet" : "Switch to the dark sheet");

  const show = (value) => {
    if (value === "light" || value === "dark") {
      root.dataset.theme = value;
      root.style.colorScheme = value;
    } else {
      // Nothing stored: the system decides again, and the stylesheet's media query hears it.
      delete root.dataset.theme;
      root.style.removeProperty("color-scheme");
    }
    if (button) {
      button.setAttribute("aria-label", label());
      button.title = label();
    }
  };

  // If the head script did not run — blocked, failed, cached away — the choice is still here.
  if (!root.dataset.theme) {
    try {
      const stored = sessionStorage.getItem(KEY);
      if (stored === "light" || stored === "dark") {
        root.dataset.theme = stored;
        root.style.colorScheme = stored;
      }
    } catch {
      // Nothing to read; the system decides.
    }
  }

  show(root.dataset.theme);

  button?.addEventListener("click", () => {
    const next = current() === "dark" ? "light" : "dark";
    // The document turns first, so the page still switches when storage is refused.
    show(next);
    try {
      sessionStorage.setItem(KEY, next);
    } catch {
      // A page that cannot remember still switches.
    }
  });

  // With no stored choice the label has to follow the system, which may change under the page.
  matchMedia("(prefers-color-scheme: dark)").addEventListener("change", () => {
    show(root.dataset.theme);
  });

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
    // thread whatever the width. Above the thread there is nothing for it to sit on.
    const at = innerHeight * 0.42 - top;
    bead.style.top = `${Math.max(0, at)}px`;
    bead.style.opacity = at < 0 ? "0" : "1";
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
})();
