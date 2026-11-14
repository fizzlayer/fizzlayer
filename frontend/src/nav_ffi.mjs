import * as nav from "./nav.mjs";

export function install() {
  const navToggle = document.getElementById("nav-toggle");
  const navLinks = document.getElementById("nav-links");
  if (!navToggle || !navLinks) return;
  const apply = (eventName) => {
    const open = navLinks.classList.contains("open");
    const next = nav.menu_open(open, eventName);
    navLinks.classList.toggle("open", next);
    navToggle.setAttribute("aria-expanded", String(next));
    if (nav.menu_focus(open, eventName)) navToggle.focus();
  };
  navToggle.addEventListener("click", () => apply("toggle"));
  navLinks.addEventListener("click", (event) => {
    if (event.target.closest("a")) apply("link");
  });
  addEventListener("keydown", (event) => {
    if (event.key === "Escape") apply("escape");
  });
}
