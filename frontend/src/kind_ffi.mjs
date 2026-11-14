import * as kind from "./kind.mjs";

const numbers = new Intl.NumberFormat(undefined, { maximumFractionDigits: 2 });
const relative = new Intl.RelativeTimeFormat(undefined, { numeric: "auto" });

function plainKind(name) {
  return {
    label: kind.kind_label(name),
    detail: kind.kind_detail(name),
    metric: kind.kind_metric(name),
    unit: kind.kind_unit(name),
    color: kind.kind_color(name),
    example: kind.kind_example(name),
    icon: kind.kind_icon(name),
  };
}

function icon(name) {
  const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  svg.setAttribute("viewBox", `0 0 ${kind.icon_width(name)} 512`);
  svg.setAttribute("aria-hidden", "true");
  const path = document.createElementNS("http://www.w3.org/2000/svg", "path");
  path.setAttribute("d", kind.icon_path(name));
  svg.append(path);
  return svg;
}

function badge(name, className = "kind-badge") {
  const element = document.createElement("span");
  element.className = className;
  element.style.setProperty("--sensor-color", kind.badge_color(name));
  element.append(icon(name));
  return element;
}

function formatValue(value, unit) {
  const text = typeof value === "number" ? numbers.format(value) : String(value);
  return kind.format_value(text, unit ?? "");
}

function formatReading(reading) {
  if (!reading) return kind.format_reading(false, "", "", false, false, "");
  const hasFlag = typeof reading.boolean_value === "boolean";
  const value = reading.numeric_value ?? reading.boolean_value ?? reading.text_value;
  const text = typeof value === "number" ? numbers.format(value) : String(value);
  return kind.format_reading(
    true,
    typeof reading.metric === "string" ? reading.metric : "",
    typeof reading.unit === "string" ? reading.unit : "",
    hasFlag,
    hasFlag ? reading.boolean_value : false,
    text,
  );
}

function timeAgo(value) {
  const ms = new Date(value).getTime();
  if (!Number.isFinite(ms)) return "";
  const seconds = Math.round((ms - Date.now()) / 1000);
  return kind.time_ago(seconds, (unit, amount) => relative.format(amount, unit));
}

function metricScale(metric, unit) {
  const name = typeof metric === "string" ? metric : "";
  const suffix = typeof unit === "string" ? unit : "";
  if (!kind.has_scale(name, suffix)) return null;
  const scale = { min: kind.scale_min(name, suffix), max: kind.scale_max(name, suffix) };
  if (kind.has_alarm(name, suffix)) {
    scale.warn = kind.scale_warn(name, suffix);
    scale.danger = kind.scale_danger(name, suffix);
  }
  return scale;
}

function metricLevel(reading) {
  if (!reading) return kind.metric_level(false, "", "", false, false, false, 0);
  const hasFlag = typeof reading.boolean_value === "boolean";
  const hasNumber = typeof reading.numeric_value === "number" && Number.isFinite(reading.numeric_value);
  return kind.metric_level(
    true,
    typeof reading.metric === "string" ? reading.metric : "",
    typeof reading.unit === "string" ? reading.unit : "",
    hasFlag,
    hasFlag ? reading.boolean_value : false,
    hasNumber,
    hasNumber ? reading.numeric_value : 0,
  );
}

function shapeOf(reading) {
  if (reading.numeric_value != null) return "number";
  if (reading.boolean_value != null) return "flag";
  return "text";
}

function sortMetrics(readings, kindName) {
  const list = Array.isArray(readings) ? readings : Array.from(readings ?? []);
  const name = typeof kindName === "string" ? kindName : "";
  return [...list].sort((left, right) =>
    kind.compare_metrics(
      typeof left.metric === "string" ? left.metric : "",
      shapeOf(left),
      typeof right.metric === "string" ? right.metric : "",
      shapeOf(right),
      name,
    ),
  );
}

export function install() {
  const names = kind.order();
  window.fizzKinds = {
    order: typeof names.toArray === "function" ? names.toArray() : names,
    get: plainKind,
    icon,
    badge,
    metricLabel: (metric) => kind.metric_label(typeof metric === "string" ? metric : ""),
    formatValue,
    formatReading,
    timeAgo,
    metricScale,
    metricLevel,
    sortMetrics,
    formatBoolean: (reading) =>
      kind.format_boolean(
        typeof reading?.metric === "string" ? reading.metric : "",
        Boolean(reading?.boolean_value),
      ),
  };
}
