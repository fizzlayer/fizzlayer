// Vercel Web Analytics: cookieless page views. Kept in a file because the CSP blocks inline scripts.
// Only the page path is sent: query strings and fragments can carry sign-in links, pairing codes,
// or billing results, so they are removed before any event leaves the browser.
(() => {
  window.va = window.va || function () { (window.vaq = window.vaq || []).push(arguments); };
  window.va('beforeSend', (event) => {
    try {
      const url = new URL(event.url, location.origin);
      return { ...event, url: url.origin + url.pathname };
    } catch {
      return null;
    }
  });
  // The insights routes exist only on Vercel deployments with Web Analytics enabled.
  if (['localhost', '127.0.0.1', '[::1]'].includes(location.hostname)) return;
  const script = document.createElement('script');
  script.src = '/_vercel/insights/script.js';
  script.defer = true;
  document.head.append(script);
})();
