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
