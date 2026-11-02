// Documentation page: copy buttons on code blocks and the current section highlighted in the sidebar.
(() => {
  for (const pre of document.querySelectorAll('.legal-body pre')) {
    const wrap = document.createElement('div');
    wrap.className = 'docs-code';
    pre.replaceWith(wrap);
    wrap.append(pre);
    if (!navigator.clipboard) continue;
    const button = document.createElement('button');
    button.type = 'button';
    button.className = 'docs-copy';
    button.textContent = 'Copy';
    button.setAttribute('aria-label', 'Copy code');
    let reset;
    button.addEventListener('click', async () => {
      try {
        await navigator.clipboard.writeText(pre.innerText.replace(/\n$/, ''));
        button.textContent = 'Copied';
      } catch {
        button.textContent = 'Press Ctrl+C';
        getSelection()?.selectAllChildren(pre);
      }
      clearTimeout(reset);
      reset = setTimeout(() => { button.textContent = 'Copy'; }, 1800);
    });
    wrap.append(button);
  }

  const links = new Map([...document.querySelectorAll('.docs-toc a[href^="#"]')].map((a) => [a.getAttribute('href').slice(1), a]));
  const sections = [...links.keys()].map((id) => document.getElementById(id)).filter(Boolean);
  if (!sections.length) return;
  let queued = false;
  const update = () => {
    queued = false;
    // The current section is the last heading that has scrolled past the top third of the screen.
    let current = sections[0];
    for (const section of sections) if (section.getBoundingClientRect().top < innerHeight / 3) current = section;
    for (const [id, a] of links) {
      const active = id === current.id;
      a.classList.toggle('is-active', active);
      if (active) a.setAttribute('aria-current', 'location'); else a.removeAttribute('aria-current');
    }
  };
  addEventListener('scroll', () => { if (!queued) { queued = true; requestAnimationFrame(update); } }, { passive: true });
  update();
})();
