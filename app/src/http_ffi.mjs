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
