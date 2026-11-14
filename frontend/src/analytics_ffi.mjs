import * as analytics from "./analytics.mjs";

export function install() {
  window.va = window.va || function () {
    (window.vaq = window.vaq || []).push(arguments);
  };
  window.va("beforeSend", (event) => {
    try {
      const url = new URL(event.url, location.origin);
      return { ...event, url: analytics.page_url(url.origin, url.pathname) };
    } catch {
      return null;
    }
  });
  if (!analytics.track_on_this_host(location.hostname)) return;
  const script = document.createElement("script");
  script.src = "/_vercel/insights/script.js";
  script.defer = true;
  document.head.append(script);
}
