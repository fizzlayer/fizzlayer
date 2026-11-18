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

// Lists tool names from a remote MCP server. The credential is a request
// header only. Failures never include it, and the raw response is not returned.
export function probe_tools(url, authKind, apiKey, done) {
  const fail = (message) => {
    const text = String(message || "The server did not list tools.");
    const clean =
      apiKey && text.includes(apiKey) ? "The server refused the request." : text;
    done([false, clean]);
  };
  let parsed;
  try {
    parsed = new URL(url);
  } catch {
    fail("That URL is not usable.");
    return;
  }
  if (
    parsed.username ||
    parsed.password ||
    (parsed.protocol !== "https:" && parsed.protocol !== "http:")
  ) {
    fail("That URL is not usable.");
    return;
  }
  if (authKind === "passthrough") {
    fail("This server uses the client's own token. Tools show up after a client connects.");
    return;
  }
  const headers = {
    "content-type": "application/json",
    accept: "application/json, text/event-stream",
  };
  if (authKind === "key" && apiKey) headers.authorization = "Bearer " + apiKey;
  const post = (body, session) => {
    const init = {
      method: "POST",
      headers: { ...headers },
      body: JSON.stringify(body),
      redirect: "error",
    };
    if (session) init.headers["mcp-session-id"] = session;
    if (typeof AbortSignal !== "undefined" && AbortSignal.timeout) {
      init.signal = AbortSignal.timeout(8000);
    }
    return fetch(parsed.toString(), init);
  };
  post({
    jsonrpc: "2.0",
    id: 1,
    method: "initialize",
    params: {
      protocolVersion: "2025-03-26",
      capabilities: {},
      clientInfo: { name: "fizzlayer", version: "0.1.0" },
    },
  })
    .then(async (response) => {
      if (!response.ok) {
        fail("The server did not list tools.");
        return;
      }
      const session = response.headers.get("mcp-session-id") || "";
      await response.text();
      try {
        await post({ jsonrpc: "2.0", method: "notifications/initialized" }, session);
      } catch {
        /* some servers have no body for a notification */
      }
      const listed = await post(
        { jsonrpc: "2.0", id: 2, method: "tools/list", params: {} },
        session,
      );
      const names = tool_names(await listed.text());
      if (!names) {
        fail("The server did not return a tool list.");
        return;
      }
      done([true, JSON.stringify(names)]);
    })
    .catch(() =>
      fail("This browser couldn't reach that server. Name the tools, or pin them after the gateway lists them."),
    );
}

function tool_names(text) {
  const lines = String(text).split("\n");
  const chunks = [];
  for (const line of lines) {
    const trimmed = line.trim();
    if (trimmed.startsWith("data:")) chunks.push(trimmed.slice(5).trim());
  }
  const candidates = chunks.length ? chunks : [text];
  for (const candidate of candidates) {
    try {
      const parsed = JSON.parse(candidate);
      const tools = parsed && parsed.result && parsed.result.tools;
      if (!Array.isArray(tools)) continue;
      return tools
        .map((tool) => tool && tool.name)
        .filter((name) => typeof name === "string" && name.length > 0 && name.length <= 128);
    } catch {
      /* try the next chunk */
    }
  }
  return null;
}
