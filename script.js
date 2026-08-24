// Scroll reveals via IntersectionObserver — transform/opacity only, gated behind reduced motion
const prefersReducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

if (!prefersReducedMotion && "IntersectionObserver" in window) {
  const observer = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) {
        if (entry.isIntersecting) {
          entry.target.classList.add("is-visible");
          observer.unobserve(entry.target);
        }
      }
    },
    { threshold: 0.12, rootMargin: "0px 0px -8% 0px" }
  );

  document.querySelectorAll(".reveal").forEach((el) => observer.observe(el));
} else {
  document.querySelectorAll(".reveal").forEach((el) => el.classList.add("is-visible"));
}

// Mobile-Navigation: Burger-Menü öffnen/schließen
const nav = document.querySelector(".nav");
const burger = document.querySelector(".nav__burger");

if (nav && burger) {
  const setOpen = (open) => {
    nav.classList.toggle("is-open", open);
    burger.setAttribute("aria-expanded", open ? "true" : "false");
    burger.setAttribute("aria-label", open ? "Menü schließen" : "Menü öffnen");
    document.body.style.overflow = open ? "hidden" : "";
  };

  burger.addEventListener("click", () => setOpen(!nav.classList.contains("is-open")));

  nav.querySelectorAll(".nav__links a").forEach((link) => {
    link.addEventListener("click", () => setOpen(false));
  });

  document.addEventListener("keydown", (e) => {
    if (e.key === "Escape" && nav.classList.contains("is-open")) setOpen(false);
  });
}

// Portfolio-Akkordeon: eine Kategorie offen, Klick toggelt
const rows = document.querySelectorAll(".workrow");

rows.forEach((row) => {
  const head = row.querySelector(".workrow__head");
  head.addEventListener("click", () => {
    const isOpen = row.classList.contains("is-open");
    rows.forEach((r) => {
      r.classList.remove("is-open");
      r.querySelector(".workrow__head").setAttribute("aria-expanded", "false");
    });
    if (!isOpen) {
      row.classList.add("is-open");
      head.setAttribute("aria-expanded", "true");
    }
  });
});

/* ═══════════════════════════════════════════════════════════════
   MOTION — Personality: CINEMATIC
   Ergaenzt das bestehende Reveal-System. Alles hier respektiert
   prefers-reduced-motion und schreibt nur transform/opacity.
   ═══════════════════════════════════════════════════════════════ */

/* ---------- Titel in maskierte Zeilen zerlegen ----------
   Bewusst nach <br> getrennt, NICHT nach Woertern: "Leist<em>ungen</em>"
   ist im Markup ein Wort aus zwei Knoten, ein Wort-Split wuerde es
   auseinanderreissen. Der aria-Text bleibt ueber das Original erhalten,
   weil nur umverpackt und nichts neu geschrieben wird. */
document.querySelectorAll(".section__title, .contact__title").forEach((title) => {
  const segments = [[]];
  for (const node of [...title.childNodes]) {
    if (node.nodeName === "BR") segments.push([]);
    else segments[segments.length - 1].push(node);
  }
  if (!segments.some((seg) => seg.length)) return;

  title.textContent = "";
  for (const seg of segments) {
    if (!seg.length) continue;
    const mask = document.createElement("span");
    mask.className = "lnw";
    const mover = document.createElement("span");
    mover.className = "ln";
    seg.forEach((n) => mover.appendChild(n));
    mask.appendChild(mover);
    title.appendChild(mask);
  }
});

/* ---------- Zahlen hochzaehlen ----------
   Die Werte stehen als Text im Markup ("15+"), nicht als data-Attribut —
   also von dort lesen statt sie zu duplizieren. */
const counters = [...document.querySelectorAll(".about__facts b")].filter((el) =>
  /^\d+\+$/.test(el.textContent.trim())
);

function countUp(el) {
  const target = parseInt(el.textContent, 10);
  if (prefersReducedMotion) return;
  const dur = 900, t0 = performance.now();
  const step = (now) => {
    const k = Math.min(1, (now - t0) / dur);
    // ease-out, damit die Zahl weich einrastet statt linear zu rattern
    el.textContent = Math.round(target * (1 - Math.pow(1 - k, 3))) + "+";
    if (k < 1) requestAnimationFrame(step);
  };
  el.textContent = "0+";
  requestAnimationFrame(step);
}

if (counters.length && !prefersReducedMotion && "IntersectionObserver" in window) {
  const co = new IntersectionObserver(
    (entries) => {
      for (const e of entries) {
        if (!e.isIntersecting) continue;
        countUp(e.target);
        co.unobserve(e.target);
      }
    },
    { threshold: 0.6 }
  );
  counters.forEach((el) => co.observe(el));
}

/* ---------- Hero-Parallaxe ----------
   Erst wenn der Ken-Burns-Einsatz durch ist, uebernimmt JS die Transform.
   Zwei Schreiber auf derselben Eigenschaft wuerden sich sonst pruegeln.
   Auf Touch aus: auf schwacher Hardware ruckelt es mehr als es bringt. */
const heroPhoto = document.querySelector(".hero__photo");
const fine = matchMedia("(hover: hover) and (pointer: fine)").matches;

if (heroPhoto && !prefersReducedMotion && fine) {
  const start = () => {
    heroPhoto.classList.add("is-settled");
    let queued = false;
    const update = () => {
      queued = false;
      // Nur solange der Hero im Bild ist rechnen
      const y = Math.min(scrollY, innerHeight);
      heroPhoto.style.transform = `translate3d(0, ${(y * 0.14).toFixed(1)}px, 0) scale(1.02)`;
    };
    addEventListener(
      "scroll",
      () => { if (!queued) { queued = true; requestAnimationFrame(update); } },
      { passive: true }
    );
    update();
  };
  heroPhoto.addEventListener("animationend", start, { once: true });
  // Notausgang, falls die Animation nie feuert (z.B. schon abgelaufen)
  setTimeout(() => { if (!heroPhoto.classList.contains("is-settled")) start(); }, 2400);
}

/* ---------- Footer ins Reveal-System aufnehmen ---------- */
const footer = document.querySelector(".footer");
if (footer) {
  footer.classList.add("reveal");
  if (prefersReducedMotion || !("IntersectionObserver" in window)) {
    footer.classList.add("is-visible");
  } else {
    const fo = new IntersectionObserver(
      (entries) => {
        for (const e of entries) {
          if (!e.isIntersecting) continue;
          e.target.classList.add("is-visible");
          fo.unobserve(e.target);
        }
      },
      { threshold: 0.2 }
    );
    fo.observe(footer);
  }
}
