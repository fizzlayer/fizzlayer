async function read(path) {
  const response = await fetch(path, { cache: "no-store" });
  const data = await response.json().catch(() => ({}));
  if (!response.ok) {
    const message = data.error && data.error.message;
    throw new Error(message || "The check failed.");
  }
  return data;
}

function text(value) {
  if (typeof value !== "string" || value === "") return "";
  return value;
}

export function load(deliver) {
  const run = async () => {
    let apiFailed = false;
    let status = "";
    let database = "";
    try {
      const data = await read("/api/status");
      status = text(data.status);
      database = text(data.database);
    } catch {
      apiFailed = true;
    }
    let streamFailed = false;
    let enabled = false;
    try {
      const data = await read("/api/stream");
      enabled = data.enabled === true;
    } catch {
      streamFailed = true;
    }
    deliver(apiFailed, status, database, streamFailed, enabled, new Date().toLocaleString());
  };
  void run();
}
