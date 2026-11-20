// Same-origin fetch. Status 0 means the request never completed.
export function send(method, path, body, done) {
  const init = {
    method,
    credentials: "same-origin",
    cache: "no-store",
  };
  if (body) {
    init.headers = { "content-type": "application/json" };
    init.body = body;
  }
  fetch(path, init)
    .then(async (response) => {
      const text = await response.text();
      done([response.status, text]);
    })
    .catch((error) => {
      const message = error && error.message ? error.message : "Network error";
      done([0, String(message)]);
    });
}

export function assign(path) {
  if (globalThis.location) globalThis.location.assign(path);
}

export function continue_checkout(plan) {
  if (plan !== "tinkerer" && plan !== "pro") return;
  try {
    sessionStorage.setItem("fizz.afterCheckout", "gateway");
    sessionStorage.setItem("fizz.expectSignup", "1");
  } catch {
    /* sessionStorage can throw in private mode */
  }
  if (globalThis.location) {
    globalThis.location.assign("/app.html?plan=" + encodeURIComponent(plan));
  }
}

export function copy_text(value, done) {
  const clipboard = globalThis.navigator && globalThis.navigator.clipboard;
  if (!clipboard || typeof value !== "string") {
    done([false, ""]);
    return;
  }
  clipboard.writeText(value).then(
    () => done([true, ""]),
    () => done([false, ""]),
  );
}

// Same-origin only. `/api/gateway/hosted` wins when another deploy adds it.
// Otherwise the static flag at `/gateway-hosted.json` decides.
export function hosted_probe(done) {
  const check = (url, next) => {
    fetch(url, { credentials: "same-origin", cache: "no-store" })
      .then(async (response) => {
        if (!response.ok) {
          next();
          return;
        }
        done([response.status, await response.text()]);
      })
      .catch(() => next());
  };
  check("/api/gateway/hosted", () =>
    check("/gateway-hosted.json", () => done([404, ""])),
  );
}

