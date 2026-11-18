// Same-tab clicks on links inside /app become client-side route changes.
// Everything else (the site, new-tab clicks, downloads, other origins) is left
// to the browser, so leaving the app is an ordinary page load and the Back
// button returns to the app instead of bouncing between pushed entries.
export function on_app_link(dispatch) {
  document.addEventListener('click', (event) => {
    if (event.defaultPrevented || event.button !== 0) return;
    if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
    const link = event.target instanceof Element ? event.target.closest('a[href]') : null;
    if (!link || link.target || link.hasAttribute('download')) return;
    const url = new URL(link.href, window.location.href);
    if (url.origin !== window.location.origin) return;
    if (url.pathname !== '/app' && !url.pathname.startsWith('/app/')) return;
    event.preventDefault();
    if (url.href === window.location.href) return;
    dispatch(url.pathname + url.search + url.hash);
    window.requestAnimationFrame(() => {
      if (url.hash) document.getElementById(url.hash.slice(1))?.scrollIntoView();
      else window.scrollTo(0, 0);
    });
  });
}
