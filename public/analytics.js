// Generated from frontend/ by scripts/build-frontend.sh. Do not edit.
(() => {
  // build/dev/javascript/fizzlayer_web/analytics_ffi.mjs
  function install() {
    window.va = window.va || function() {
      (window.vaq = window.vaq || []).push(arguments);
    };
    window.va("beforeSend", (event) => {
      try {
        const url = new URL(event.url, location.origin);
        return { ...event, url: page_url(url.origin, url.pathname) };
      } catch {
        return null;
      }
    });
    if (!track_on_this_host(location.hostname)) return;
    const script = document.createElement("script");
    script.src = "/_vercel/insights/script.js";
    script.defer = true;
    document.head.append(script);
  }

  // build/dev/javascript/fizzlayer_web/analytics.mjs
  function track_on_this_host(hostname) {
    if (hostname === "localhost") {
      return false;
    } else if (hostname === "127.0.0.1") {
      return false;
    } else if (hostname === "[::1]") {
      return false;
    } else {
      return true;
    }
  }
  function page_url(origin, pathname) {
    return origin + pathname;
  }
  function install2() {
    return install();
  }

  // entries/analytics.js
  install2();
})();
