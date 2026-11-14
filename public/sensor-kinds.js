// Generated from frontend/ by scripts/build-frontend.sh. Do not edit.
(() => {
  var __typeError = (msg) => {
    throw TypeError(msg);
  };
  var __accessCheck = (obj, member, msg) => member.has(obj) || __typeError("Cannot " + msg);
  var __privateGet = (obj, member, getter) => (__accessCheck(obj, member, "read from private field"), getter ? getter.call(obj) : member.get(obj));
  var __privateAdd = (obj, member, value) => member.has(obj) ? __typeError("Cannot add the same private member more than once") : member instanceof WeakSet ? member.add(obj) : member.set(obj, value);
  var __privateSet = (obj, member, value, setter) => (__accessCheck(obj, member, "write to private field"), setter ? setter.call(obj, value) : member.set(obj, value), value);

  // build/dev/javascript/prelude.mjs
  var CustomType = class {
    withFields(fields) {
      let properties = Object.keys(this).map(
        (label) => label in fields ? fields[label] : this[label]
      );
      return new this.constructor(...properties);
    }
  };
  var List = class {
    static fromArray(array, tail) {
      return toList(array, tail);
    }
    [Symbol.iterator]() {
      return new ListIterator(this);
    }
    toArray() {
      return [...this];
    }
    atLeastLength(desired) {
      let current = this;
      while (desired-- > 0 && current) current = current.tail;
      return current !== void 0;
    }
    hasLength(desired) {
      let current = this;
      while (desired-- > 0 && current) current = current.tail;
      return desired === -1 && current instanceof Empty;
    }
    countLength() {
      let current = this;
      let length3 = 0;
      while (current) {
        current = current.tail;
        length3++;
      }
      return length3 - 1;
    }
  };
  function prepend(element, tail) {
    return new NonEmpty(element, tail);
  }
  function toList(elements, tail) {
    let t = tail || List$Empty$const;
    for (let i = elements.length - 1; i >= 0; --i) {
      t = new NonEmpty(elements[i], t);
    }
    return t;
  }
  var _current;
  var ListIterator = class {
    constructor(current) {
      __privateAdd(this, _current);
      __privateSet(this, _current, current);
    }
    next() {
      if (__privateGet(this, _current) instanceof Empty) {
        return { done: true };
      } else {
        let { head, tail } = __privateGet(this, _current);
        __privateSet(this, _current, tail);
        return { value: head, done: false };
      }
    }
  };
  _current = new WeakMap();
  var Empty = class extends List {
  };
  var List$Empty$const = new Empty();
  var NonEmpty = class extends List {
    constructor(head, tail) {
      super();
      this.head = head;
      this.tail = tail;
    }
  };
  var Result = class _Result extends CustomType {
    static isResult(data) {
      return data instanceof _Result;
    }
  };
  var Ok = class extends Result {
    constructor(value) {
      super();
      this[0] = value;
    }
    isOk() {
      return true;
    }
  };
  var Result$Ok = (value) => new Ok(value);
  var Error2 = class extends Result {
    constructor(detail) {
      super();
      this[0] = detail;
    }
    isOk() {
      return false;
    }
  };
  var Result$Error = (detail) => new Error2(detail);

  // build/dev/javascript/gleam_stdlib/gleam/order.mjs
  var Lt = class extends CustomType {
  };
  var Order$Lt$const = new Lt();
  var Eq = class extends CustomType {
  };
  var Order$Eq$const = new Eq();
  var Gt = class extends CustomType {
  };
  var Order$Gt$const = new Gt();
  function to_int(order2) {
    if (order2 instanceof Lt) {
      return -1;
    } else if (order2 instanceof Eq) {
      return 0;
    } else {
      return 1;
    }
  }

  // build/dev/javascript/gleam_stdlib/gleam/option.mjs
  var None = class extends CustomType {
  };
  var Option$None$const = new None();

  // build/dev/javascript/gleam_stdlib/gleam/int.mjs
  function absolute_value(x) {
    let $ = x >= 0;
    if ($) {
      return x;
    } else {
      return x * -1;
    }
  }
  function compare(a, b) {
    let $ = a === b;
    if ($) {
      return Order$Eq$const;
    } else {
      let $1 = a < b;
      if ($1) {
        return Order$Lt$const;
      } else {
        return Order$Gt$const;
      }
    }
  }

  // build/dev/javascript/gleam_stdlib/dict.mjs
  var bits = 5;
  var mask = (1 << bits) - 1;
  var noElementMarker = Symbol();

  // build/dev/javascript/gleam_stdlib/gleam/list.mjs
  var Ascending = class extends CustomType {
  };
  var Sorting$Ascending$const = new Ascending();
  var Descending = class extends CustomType {
  };
  var Sorting$Descending$const = new Descending();
  function length_loop(loop$list, loop$count) {
    while (true) {
      let list2 = loop$list;
      let count = loop$count;
      if (list2 instanceof Empty) {
        return count;
      } else {
        let list$1 = list2.tail;
        loop$list = list$1;
        loop$count = count + 1;
      }
    }
  }
  function length(list2) {
    return length_loop(list2, 0);
  }

  // build/dev/javascript/gleam_stdlib/gleam/string_tree.mjs
  var All = class extends CustomType {
  };
  var Direction$All$const = new All();

  // build/dev/javascript/gleam_stdlib/gleam/string.mjs
  var Leading = class extends CustomType {
  };
  var Direction$Leading$const = new Leading();
  var Trailing = class extends CustomType {
  };
  var Direction$Trailing$const = new Trailing();
  function replace(string2, pattern, substitute) {
    let _pipe = string2;
    let _pipe$1 = identity(_pipe);
    let _pipe$2 = string_replace(_pipe$1, pattern, substitute);
    return identity(_pipe$2);
  }
  function compare3(a, b) {
    let $ = a === b;
    if ($) {
      return Order$Eq$const;
    } else {
      let $1 = less_than(a, b);
      if ($1) {
        return Order$Lt$const;
      } else {
        return Order$Gt$const;
      }
    }
  }
  function drop_start(string2, num_graphemes) {
    let $ = num_graphemes <= 0;
    if ($) {
      return string2;
    } else {
      let prefix = string_grapheme_slice(string2, 0, num_graphemes);
      let prefix_size = byte_size(prefix);
      return string_byte_slice(
        string2,
        prefix_size,
        byte_size(string2) - prefix_size
      );
    }
  }
  function first(string2) {
    let $ = pop_grapheme(string2);
    if ($ instanceof Ok) {
      let first$1 = $[0][0];
      return new Ok(first$1);
    } else {
      return $;
    }
  }

  // build/dev/javascript/gleam_stdlib/gleam_stdlib.mjs
  var Nil = void 0;
  function identity(x) {
    return x;
  }
  function string_replace(string2, target, substitute) {
    return string2.replaceAll(target, substitute);
  }
  var segmenter = void 0;
  function graphemes_iterator(string2) {
    if (globalThis.Intl && Intl.Segmenter) {
      segmenter || (segmenter = new Intl.Segmenter());
      return segmenter.segment(string2)[Symbol.iterator]();
    }
  }
  function pop_grapheme(string2) {
    let first2;
    const iterator = graphemes_iterator(string2);
    if (iterator) {
      first2 = iterator.next().value?.segment;
    } else {
      first2 = string2.match(/./su)?.[0];
    }
    if (first2) {
      return Result$Ok([first2, string2.slice(first2.length)]);
    } else {
      return Result$Error(Nil);
    }
  }
  function uppercase(string2) {
    return string2.toUpperCase();
  }
  function less_than(a, b) {
    return a < b;
  }
  function string_byte_slice(string2, index2, length3) {
    return string2.slice(index2, index2 + length3);
  }
  function string_grapheme_slice(string2, idx, len) {
    if (len <= 0 || idx >= string2.length) {
      return "";
    }
    const iterator = graphemes_iterator(string2);
    if (iterator) {
      while (idx-- > 0) {
        iterator.next();
      }
      let result = "";
      while (len-- > 0) {
        const v = iterator.next().value;
        if (v === void 0) {
          break;
        }
        result += v.segment;
      }
      return result;
    } else {
      return string2.match(/./gsu).slice(idx, idx + len).join("");
    }
  }
  function ends_with(haystack, needle) {
    return haystack.endsWith(needle);
  }
  var unicode_whitespaces = [
    " ",
    // Space
    "	",
    // Horizontal tab
    "\n",
    // Line feed
    "\v",
    // Vertical tab
    "\f",
    // Form feed
    "\r",
    // Carriage return
    "\x85",
    // Next line
    "\u2028",
    // Line separator
    "\u2029"
    // Paragraph separator
  ].join("");
  var trim_start_regex = /* @__PURE__ */ new RegExp(
    `^[${unicode_whitespaces}]*`
  );
  var trim_end_regex = /* @__PURE__ */ new RegExp(`[${unicode_whitespaces}]*$`);
  function floor(float2) {
    return Math.floor(float2);
  }
  function truncate(float2) {
    return Math.trunc(float2);
  }
  function byte_size(string2) {
    return new TextEncoder().encode(string2).length;
  }
  var MIN_I32 = -(2 ** 31);
  var MAX_I32 = 2 ** 31 - 1;
  var U32 = 2 ** 32;
  var MAX_SAFE = Number.MAX_SAFE_INTEGER;
  var MIN_SAFE = Number.MIN_SAFE_INTEGER;

  // build/dev/javascript/fizzlayer_web/kind_ffi.mjs
  var numbers = new Intl.NumberFormat(void 0, { maximumFractionDigits: 2 });
  var relative = new Intl.RelativeTimeFormat(void 0, { numeric: "auto" });
  function plainKind(name) {
    return {
      label: kind_label(name),
      detail: kind_detail(name),
      metric: kind_metric(name),
      unit: kind_unit(name),
      color: kind_color(name),
      example: kind_example(name),
      icon: kind_icon(name)
    };
  }
  function icon(name) {
    const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    svg.setAttribute("viewBox", `0 0 ${icon_width(name)} 512`);
    svg.setAttribute("aria-hidden", "true");
    const path = document.createElementNS("http://www.w3.org/2000/svg", "path");
    path.setAttribute("d", icon_path(name));
    svg.append(path);
    return svg;
  }
  function badge(name, className = "kind-badge") {
    const element = document.createElement("span");
    element.className = className;
    element.style.setProperty("--sensor-color", badge_color(name));
    element.append(icon(name));
    return element;
  }
  function formatValue(value, unit) {
    const text = typeof value === "number" ? numbers.format(value) : String(value);
    return format_value(text, unit ?? "");
  }
  function formatReading(reading) {
    if (!reading) return format_reading(false, "", "", false, false, "");
    const hasFlag = typeof reading.boolean_value === "boolean";
    const value = reading.numeric_value ?? reading.boolean_value ?? reading.text_value;
    const text = typeof value === "number" ? numbers.format(value) : String(value);
    return format_reading(
      true,
      typeof reading.metric === "string" ? reading.metric : "",
      typeof reading.unit === "string" ? reading.unit : "",
      hasFlag,
      hasFlag ? reading.boolean_value : false,
      text
    );
  }
  function timeAgo(value) {
    const ms = new Date(value).getTime();
    if (!Number.isFinite(ms)) return "";
    const seconds = Math.round((ms - Date.now()) / 1e3);
    return time_ago(seconds, (unit, amount) => relative.format(amount, unit));
  }
  function metricScale(metric, unit) {
    const name = typeof metric === "string" ? metric : "";
    const suffix = typeof unit === "string" ? unit : "";
    if (!has_scale(name, suffix)) return null;
    const scale = { min: scale_min(name, suffix), max: scale_max(name, suffix) };
    if (has_alarm(name, suffix)) {
      scale.warn = scale_warn(name, suffix);
      scale.danger = scale_danger(name, suffix);
    }
    return scale;
  }
  function metricLevel(reading) {
    if (!reading) return metric_level(false, "", "", false, false, false, 0);
    const hasFlag = typeof reading.boolean_value === "boolean";
    const hasNumber = typeof reading.numeric_value === "number" && Number.isFinite(reading.numeric_value);
    return metric_level(
      true,
      typeof reading.metric === "string" ? reading.metric : "",
      typeof reading.unit === "string" ? reading.unit : "",
      hasFlag,
      hasFlag ? reading.boolean_value : false,
      hasNumber,
      hasNumber ? reading.numeric_value : 0
    );
  }
  function shapeOf(reading) {
    if (reading.numeric_value != null) return "number";
    if (reading.boolean_value != null) return "flag";
    return "text";
  }
  function sortMetrics(readings, kindName) {
    const list2 = Array.isArray(readings) ? readings : Array.from(readings ?? []);
    const name = typeof kindName === "string" ? kindName : "";
    return [...list2].sort(
      (left, right) => compare_metrics(
        typeof left.metric === "string" ? left.metric : "",
        shapeOf(left),
        typeof right.metric === "string" ? right.metric : "",
        shapeOf(right),
        name
      )
    );
  }
  function install() {
    const names = order();
    window.fizzKinds = {
      order: typeof names.toArray === "function" ? names.toArray() : names,
      get: plainKind,
      icon,
      badge,
      metricLabel: (metric) => metric_label(typeof metric === "string" ? metric : ""),
      formatValue,
      formatReading,
      timeAgo,
      metricScale,
      metricLevel,
      sortMetrics,
      formatBoolean: (reading) => format_boolean(
        typeof reading?.metric === "string" ? reading.metric : "",
        Boolean(reading?.boolean_value)
      )
    };
  }

  // build/dev/javascript/fizzlayer_web/kind.mjs
  var Kind = class extends CustomType {
    constructor(label, detail, metric, unit, color, example, icon2) {
      super();
      this.label = label;
      this.detail = detail;
      this.metric = metric;
      this.unit = unit;
      this.color = color;
      this.example = example;
      this.icon = icon2;
    }
  };
  var Quiet = class extends CustomType {
  };
  var Alarm$Quiet$const = new Quiet();
  var Rising = class extends CustomType {
    constructor(warn, danger) {
      super();
      this.warn = warn;
      this.danger = danger;
    }
  };
  var Scale = class extends CustomType {
    constructor(min, max, alarm) {
      super();
      this.min = min;
      this.max = max;
      this.alarm = alarm;
    }
  };
  var JustNow = class extends CustomType {
  };
  var Ago$JustNow$const = new JustNow();
  var Minutes = class extends CustomType {
    constructor($0) {
      super();
      this[0] = $0;
    }
  };
  var Hours = class extends CustomType {
    constructor($0) {
      super();
      this[0] = $0;
    }
  };
  var Days = class extends CustomType {
    constructor($0) {
      super();
      this[0] = $0;
    }
  };
  function order() {
    return prepend(
      "water",
      prepend(
        "gas",
        prepend(
          "radio",
          prepend(
            "temperature",
            prepend(
              "pressure",
              prepend(
                "humidity",
                prepend(
                  "sound",
                  prepend("phone", prepend("custom", List$Empty$const))
                )
              )
            )
          )
        )
      )
    );
  }
  function custom_kind() {
    return new Kind(
      "Custom",
      "Your own metric",
      "value",
      "",
      "#ff9ed2",
      "Bike rack counter",
      "sliders"
    );
  }
  function fallback() {
    let $ = custom_kind();
    let icon2 = $.icon;
    return new Kind("Sensor", "", "value", "", "#a9eaf7", "My sensor", icon2);
  }
  function phone_kind() {
    return new Kind(
      "Phone",
      "Motion, voice & location",
      "acceleration_ms2",
      "m/s\xB2",
      "#8c9dff",
      "My phone",
      "mobile-screen-button"
    );
  }
  function sound_kind() {
    return new Kind(
      "Sound",
      "Audio events",
      "sound_db",
      "dB",
      "#ffa94d",
      "Nursery sound",
      "volume-high"
    );
  }
  function humidity_kind() {
    return new Kind(
      "Humidity",
      "Moisture",
      "humidity_pct",
      "%",
      "#5ee6c4",
      "Greenhouse humidity",
      "droplet"
    );
  }
  function pressure_kind() {
    return new Kind(
      "Pressure",
      "Force & level",
      "pressure_kpa",
      "kPa",
      "#c79bff",
      "Boiler pressure",
      "gauge-high"
    );
  }
  function temperature_kind() {
    return new Kind(
      "Temperature",
      "Hot & cold",
      "temperature_c",
      "\xB0C",
      "#ff7b6b",
      "Kitchen temperature",
      "temperature-half"
    );
  }
  function radio_kind() {
    return new Kind(
      "Radio",
      "Signals & waves",
      "rssi_dbm",
      "dBm",
      "#ffe066",
      "Rooftop antenna",
      "satellite-dish"
    );
  }
  function gas_kind() {
    return new Kind(
      "Gas",
      "Air safety",
      "concentration_ppm",
      "ppm",
      "#9be07a",
      "Garage air",
      "smog"
    );
  }
  function water_kind() {
    return new Kind(
      "Water",
      "Leaks & flow",
      "flow_l_min",
      "L/min",
      "#5cc8ff",
      "Basement leak",
      "faucet-drip"
    );
  }
  function catalogue(name) {
    if (name === "water") {
      return new Ok(water_kind());
    } else if (name === "gas") {
      return new Ok(gas_kind());
    } else if (name === "radio") {
      return new Ok(radio_kind());
    } else if (name === "temperature") {
      return new Ok(temperature_kind());
    } else if (name === "pressure") {
      return new Ok(pressure_kind());
    } else if (name === "humidity") {
      return new Ok(humidity_kind());
    } else if (name === "sound") {
      return new Ok(sound_kind());
    } else if (name === "phone") {
      return new Ok(phone_kind());
    } else if (name === "custom") {
      return new Ok(custom_kind());
    } else {
      return new Error2(void 0);
    }
  }
  function get2(name) {
    let $ = catalogue(name);
    if ($ instanceof Ok) {
      let kind = $[0];
      return kind;
    } else {
      return fallback();
    }
  }
  function kind_label(name) {
    return get2(name).label;
  }
  function kind_detail(name) {
    return get2(name).detail;
  }
  function kind_metric(name) {
    return get2(name).metric;
  }
  function kind_unit(name) {
    return get2(name).unit;
  }
  function kind_color(name) {
    return get2(name).color;
  }
  function kind_example(name) {
    return get2(name).example;
  }
  function kind_icon(name) {
    return get2(name).icon;
  }
  function icon_art(loop$name) {
    while (true) {
      let name = loop$name;
      if (name === "droplet") {
        return [
          384,
          "M192 512C86 512 0 426 0 320C0 228.8 130.2 57.7 166.6 11.7C172.6 4.2 181.5 0 191.1 0l1.8 0c9.6 0 18.5 4.2 24.5 11.7C253.8 57.7 384 228.8 384 320c0 106-86 192-192 192zM96 336c0-8.8-7.2-16-16-16s-16 7.2-16 16c0 61.9 50.1 112 112 112c8.8 0 16-7.2 16-16s-7.2-16-16-16c-44.2 0-80-35.8-80-80z"
        ];
      } else if (name === "faucet-drip") {
        return [
          512,
          "M224 0c17.7 0 32 14.3 32 32l0 12 96-12c17.7 0 32 14.3 32 32s-14.3 32-32 32L256 84l-31-3.9-1-.1-1 .1L192 84 96 96C78.3 96 64 81.7 64 64s14.3-32 32-32l96 12 0-12c0-17.7 14.3-32 32-32zM0 224c0-17.7 14.3-32 32-32l96 0 22.6-22.6c6-6 14.1-9.4 22.6-9.4l18.7 0 0-43.8 32-4 32 4 0 43.8 18.7 0c8.5 0 16.6 3.4 22.6 9.4L320 192l32 0c88.4 0 160 71.6 160 160c0 17.7-14.3 32-32 32l-64 0c-17.7 0-32-14.3-32-32s-14.3-32-32-32l-36.1 0c-20.2 29-53.9 48-91.9 48s-71.7-19-91.9-48L32 320c-17.7 0-32-14.3-32-32l0-64zM436.8 423.4c1.9-4.5 6.3-7.4 11.2-7.4s9.2 2.9 11.2 7.4l18.2 42.4c1.8 4.1 2.7 8.6 2.7 13.1l0 1.2c0 17.7-14.3 32-32 32s-32-14.3-32-32l0-1.2c0-4.5 .9-8.9 2.7-13.1l18.2-42.4z"
        ];
      } else if (name === "gauge-high") {
        return [
          512,
          "M0 256a256 256 0 1 1 512 0A256 256 0 1 1 0 256zM288 96a32 32 0 1 0 -64 0 32 32 0 1 0 64 0zM256 416c35.3 0 64-28.7 64-64c0-17.4-6.9-33.1-18.1-44.6L366 161.7c5.3-12.1-.2-26.3-12.3-31.6s-26.3 .2-31.6 12.3L257.9 288c-.6 0-1.3 0-1.9 0c-35.3 0-64 28.7-64 64s28.7 64 64 64zM176 144a32 32 0 1 0 -64 0 32 32 0 1 0 64 0zM96 288a32 32 0 1 0 0-64 32 32 0 1 0 0 64zm352-32a32 32 0 1 0 -64 0 32 32 0 1 0 64 0z"
        ];
      } else if (name === "mobile-screen-button") {
        return [
          384,
          "M16 64C16 28.7 44.7 0 80 0L304 0c35.3 0 64 28.7 64 64l0 384c0 35.3-28.7 64-64 64L80 512c-35.3 0-64-28.7-64-64L16 64zM224 448a32 32 0 1 0 -64 0 32 32 0 1 0 64 0zM304 64L80 64l0 320 224 0 0-320z"
        ];
      } else if (name === "satellite-dish") {
        return [
          512,
          "M192 32c0-17.7 14.3-32 32-32C383.1 0 512 128.9 512 288c0 17.7-14.3 32-32 32s-32-14.3-32-32C448 164.3 347.7 64 224 64c-17.7 0-32-14.3-32-32zM60.6 220.6L164.7 324.7l28.4-28.4c-.7-2.6-1.1-5.4-1.1-8.3c0-17.7 14.3-32 32-32s32 14.3 32 32s-14.3 32-32 32c-2.9 0-5.6-.4-8.3-1.1l-28.4 28.4L291.4 451.4c14.5 14.5 11.8 38.8-7.3 46.3C260.5 506.9 234.9 512 208 512C93.1 512 0 418.9 0 304c0-26.9 5.1-52.5 14.4-76.1c7.5-19 31.8-21.8 46.3-7.3zM224 96c106 0 192 86 192 192c0 17.7-14.3 32-32 32s-32-14.3-32-32c0-70.7-57.3-128-128-128c-17.7 0-32-14.3-32-32s14.3-32 32-32z"
        ];
      } else if (name === "sliders") {
        return [
          512,
          "M0 416c0 17.7 14.3 32 32 32l54.7 0c12.3 28.3 40.5 48 73.3 48s61-19.7 73.3-48L480 448c17.7 0 32-14.3 32-32s-14.3-32-32-32l-246.7 0c-12.3-28.3-40.5-48-73.3-48s-61 19.7-73.3 48L32 384c-17.7 0-32 14.3-32 32zm128 0a32 32 0 1 1 64 0 32 32 0 1 1 -64 0zM320 256a32 32 0 1 1 64 0 32 32 0 1 1 -64 0zm32-80c-32.8 0-61 19.7-73.3 48L32 224c-17.7 0-32 14.3-32 32s14.3 32 32 32l246.7 0c12.3 28.3 40.5 48 73.3 48s61-19.7 73.3-48l54.7 0c17.7 0 32-14.3 32-32s-14.3-32-32-32l-54.7 0c-12.3-28.3-40.5-48-73.3-48zM192 128a32 32 0 1 1 0-64 32 32 0 1 1 0 64zm73.3-64C253 35.7 224.8 16 192 16s-61 19.7-73.3 48L32 64C14.3 64 0 78.3 0 96s14.3 32 32 32l86.7 0c12.3 28.3 40.5 48 73.3 48s61-19.7 73.3-48L480 128c17.7 0 32-14.3 32-32s-14.3-32-32-32L265.3 64z"
        ];
      } else if (name === "smog") {
        return [
          640,
          "M32 144c0 79.5 64.5 144 144 144l123.3 0c22.6 19.9 52.2 32 84.7 32s62.1-12.1 84.7-32l27.3 0c61.9 0 112-50.1 112-112s-50.1-112-112-112c-10.7 0-21 1.5-30.8 4.3C443.8 27.7 401.1 0 352 0c-32.6 0-62.4 12.2-85.1 32.3C242.1 12.1 210.5 0 176 0C96.5 0 32 64.5 32 144zM616 368l-336 0c-13.3 0-24 10.7-24 24s10.7 24 24 24l336 0c13.3 0 24-10.7 24-24s-10.7-24-24-24zm-64 96l-112 0c-13.3 0-24 10.7-24 24s10.7 24 24 24l112 0c13.3 0 24-10.7 24-24s-10.7-24-24-24zm-192 0L24 464c-13.3 0-24 10.7-24 24s10.7 24 24 24l336 0c13.3 0 24-10.7 24-24s-10.7-24-24-24zM224 392c0-13.3-10.7-24-24-24L96 368c-13.3 0-24 10.7-24 24s10.7 24 24 24l104 0c13.3 0 24-10.7 24-24z"
        ];
      } else if (name === "temperature-half") {
        return [
          320,
          "M160 64c-26.5 0-48 21.5-48 48l0 164.5c0 17.3-7.1 31.9-15.3 42.5C86.2 332.6 80 349.5 80 368c0 44.2 35.8 80 80 80s80-35.8 80-80c0-18.5-6.2-35.4-16.7-48.9c-8.2-10.6-15.3-25.2-15.3-42.5L208 112c0-26.5-21.5-48-48-48zM48 112C48 50.2 98.1 0 160 0s112 50.1 112 112l0 164.4c0 .1 .1 .3 .2 .6c.2 .6 .8 1.6 1.7 2.8c18.9 24.4 30.1 55 30.1 88.1c0 79.5-64.5 144-144 144S16 447.5 16 368c0-33.2 11.2-63.8 30.1-88.1c.9-1.2 1.5-2.2 1.7-2.8c.1-.3 .2-.5 .2-.6L48 112zM208 368c0 26.5-21.5 48-48 48s-48-21.5-48-48c0-20.9 13.4-38.7 32-45.3L144 208c0-8.8 7.2-16 16-16s16 7.2 16 16l0 114.7c18.6 6.6 32 24.4 32 45.3z"
        ];
      } else if (name === "volume-high") {
        return [
          640,
          "M533.6 32.5C598.5 85.2 640 165.8 640 256s-41.5 170.7-106.4 223.5c-10.3 8.4-25.4 6.8-33.8-3.5s-6.8-25.4 3.5-33.8C557.5 398.2 592 331.2 592 256s-34.5-142.2-88.7-186.3c-10.3-8.4-11.8-23.5-3.5-33.8s23.5-11.8 33.8-3.5zM473.1 107c43.2 35.2 70.9 88.9 70.9 149s-27.7 113.8-70.9 149c-10.3 8.4-25.4 6.8-33.8-3.5s-6.8-25.4 3.5-33.8C475.3 341.3 496 301.1 496 256s-20.7-85.3-53.2-111.8c-10.3-8.4-11.8-23.5-3.5-33.8s23.5-11.8 33.8-3.5zm-60.5 74.5C434.1 199.1 448 225.9 448 256s-13.9 56.9-35.4 74.5c-10.3 8.4-25.4 6.8-33.8-3.5s-6.8-25.4 3.5-33.8C393.1 284.4 400 271 400 256s-6.9-28.4-17.7-37.3c-10.3-8.4-11.8-23.5-3.5-33.8s23.5-11.8 33.8-3.5zM301.1 34.8C312.6 40 320 51.4 320 64l0 384c0 12.6-7.4 24-18.9 29.2s-25 3.1-34.4-5.3L131.8 352 64 352c-35.3 0-64-28.7-64-64l0-64c0-35.3 28.7-64 64-64l67.8 0L266.7 40.1c9.4-8.4 22.9-10.4 34.4-5.3z"
        ];
      } else {
        loop$name = "sliders";
      }
    }
  }
  function icon_width(name) {
    let $ = icon_art(get2(name).icon);
    let width = $[0];
    return width;
  }
  function icon_path(name) {
    let $ = icon_art(get2(name).icon);
    let path = $[1];
    return path;
  }
  function badge_color(name) {
    return get2(name).color;
  }
  function humanise(metric) {
    let words = replace(metric, "_", " ");
    let $ = first(words);
    if ($ instanceof Ok) {
      let first2 = $[0];
      return uppercase(first2) + drop_start(words, 1);
    } else {
      return "";
    }
  }
  function known_label(metric) {
    if (metric === "temperature_c") {
      return new Ok("Temperature");
    } else if (metric === "flow_l_min") {
      return new Ok("Flow rate");
    } else if (metric === "concentration_ppm") {
      return new Ok("Gas concentration");
    } else if (metric === "rssi_dbm") {
      return new Ok("Signal strength");
    } else if (metric === "pressure_kpa") {
      return new Ok("Pressure");
    } else if (metric === "humidity_pct") {
      return new Ok("Humidity");
    } else if (metric === "sound_db") {
      return new Ok("Sound level");
    } else if (metric === "acceleration_ms2") {
      return new Ok("Acceleration");
    } else if (metric === "acceleration_x") {
      return new Ok("Acceleration X");
    } else if (metric === "acceleration_y") {
      return new Ok("Acceleration Y");
    } else if (metric === "acceleration_z") {
      return new Ok("Acceleration Z");
    } else if (metric === "rotation_alpha") {
      return new Ok("Compass heading");
    } else if (metric === "rotation_beta") {
      return new Ok("Front/back tilt");
    } else if (metric === "rotation_gamma") {
      return new Ok("Left/right tilt");
    } else if (metric === "orientation_deg") {
      return new Ok("Orientation");
    } else if (metric === "latitude") {
      return new Ok("Latitude");
    } else if (metric === "longitude") {
      return new Ok("Longitude");
    } else if (metric === "location_accuracy") {
      return new Ok("Location accuracy");
    } else if (metric === "voice_clip") {
      return new Ok("Voice clip");
    } else if (metric === "voice_level") {
      return new Ok("Voice level");
    } else if (metric === "voice_transcript") {
      return new Ok("Transcript");
    } else if (metric === "value") {
      return new Ok("Value");
    } else if (metric === "leak") {
      return new Ok("Leak");
    } else if (metric === "alarm") {
      return new Ok("Alarm");
    } else if (metric === "battery_pct") {
      return new Ok("Battery");
    } else if (metric === "cpu_temperature_c") {
      return new Ok("CPU temperature");
    } else if (metric === "cpu_used_pct") {
      return new Ok("CPU used");
    } else if (metric === "load_1m") {
      return new Ok("Load (1 min)");
    } else if (metric === "memory_used_pct") {
      return new Ok("Memory used");
    } else if (metric === "disk_used_pct") {
      return new Ok("Disk used");
    } else {
      return new Error2(void 0);
    }
  }
  function metric_label(metric) {
    if (metric === "") {
      return metric;
    } else {
      let $ = known_label(metric);
      if ($ instanceof Ok) {
        let label = $[0];
        return label;
      } else {
        return humanise(metric);
      }
    }
  }
  function format_value(text, unit) {
    if (unit === "") {
      return text;
    } else if (unit === "%") {
      return text + "%";
    } else {
      return text + " " + unit;
    }
  }
  function format_boolean(metric, value) {
    if (value) {
      if (metric === "leak") {
        return "Leak detected";
      } else if (metric === "alarm") {
        return "Alarm";
      } else {
        return "Yes";
      }
    } else if (metric === "leak") {
      return "No leak";
    } else if (metric === "alarm") {
      return "Clear";
    } else {
      return "No";
    }
  }
  function format_reading(present, metric, unit, has_flag, flag, display_text) {
    if (present) {
      let $ = metric === "voice_clip";
      if ($) {
        return "Clip received";
      } else {
        if (has_flag) {
          return format_boolean(metric, flag);
        } else {
          return format_value(display_text, unit);
        }
      }
    } else {
      return "Waiting for data";
    }
  }
  function js_round(value) {
    return truncate(floor(value + 0.5));
  }
  function describe_ago(seconds) {
    let magnitude = absolute_value(seconds);
    let $ = magnitude < 45;
    if ($) {
      return Ago$JustNow$const;
    } else {
      let $1 = magnitude < 3600;
      if ($1) {
        return new Minutes(js_round(identity(seconds) / 60));
      } else {
        let $2 = magnitude < 86400;
        if ($2) {
          return new Hours(js_round(identity(seconds) / 3600));
        } else {
          return new Days(js_round(identity(seconds) / 86400));
        }
      }
    }
  }
  function time_ago(seconds, format) {
    let $ = describe_ago(seconds);
    if ($ instanceof JustNow) {
      return "just now";
    } else if ($ instanceof Minutes) {
      let amount = $[0];
      return format("minute", amount);
    } else if ($ instanceof Hours) {
      let amount = $[0];
      return format("hour", amount);
    } else {
      let amount = $[0];
      return format("day", amount);
    }
  }
  function known_scale(metric) {
    if (metric === "temperature_c") {
      return new Ok(new Scale(-20, 50, Alarm$Quiet$const));
    } else if (metric === "cpu_temperature_c") {
      return new Ok(new Scale(20, 100, new Rising(70, 85)));
    } else if (metric === "cpu_used_pct") {
      return new Ok(new Scale(0, 100, new Rising(80, 95)));
    } else if (metric === "memory_used_pct") {
      return new Ok(new Scale(0, 100, new Rising(80, 92)));
    } else if (metric === "disk_used_pct") {
      return new Ok(new Scale(0, 100, new Rising(85, 95)));
    } else if (metric === "battery_pct") {
      return new Ok(new Scale(0, 100, Alarm$Quiet$const));
    } else if (metric === "humidity_pct") {
      return new Ok(new Scale(0, 100, Alarm$Quiet$const));
    } else if (metric === "flow_l_min") {
      return new Ok(new Scale(0, 30, Alarm$Quiet$const));
    } else if (metric === "concentration_ppm") {
      return new Ok(new Scale(0, 2e3, Alarm$Quiet$const));
    } else if (metric === "rssi_dbm") {
      return new Ok(new Scale(-110, -30, Alarm$Quiet$const));
    } else if (metric === "pressure_kpa") {
      return new Ok(new Scale(0, 200, Alarm$Quiet$const));
    } else if (metric === "sound_db") {
      return new Ok(new Scale(0, 120, new Rising(85, 100)));
    } else if (metric === "acceleration_ms2") {
      return new Ok(new Scale(0, 30, Alarm$Quiet$const));
    } else if (metric === "orientation_deg") {
      return new Ok(new Scale(0, 360, Alarm$Quiet$const));
    } else if (metric === "rotation_alpha") {
      return new Ok(new Scale(0, 360, Alarm$Quiet$const));
    } else if (metric === "rotation_beta") {
      return new Ok(new Scale(-180, 180, Alarm$Quiet$const));
    } else if (metric === "rotation_gamma") {
      return new Ok(new Scale(-90, 90, Alarm$Quiet$const));
    } else {
      return new Error2(void 0);
    }
  }
  function metric_scale(metric, unit) {
    let $ = known_scale(metric);
    if ($ instanceof Ok) {
      return $;
    } else {
      let $1 = unit === "%" || ends_with(metric, "_pct");
      if ($1) {
        return new Ok(new Scale(0, 100, Alarm$Quiet$const));
      } else {
        return new Error2(void 0);
      }
    }
  }
  function has_scale(metric, unit) {
    let $ = metric_scale(metric, unit);
    if ($ instanceof Ok) {
      return true;
    } else {
      return false;
    }
  }
  function scale_min(metric, unit) {
    let $ = metric_scale(metric, unit);
    if ($ instanceof Ok) {
      let min = $[0].min;
      return min;
    } else {
      return 0;
    }
  }
  function scale_max(metric, unit) {
    let $ = metric_scale(metric, unit);
    if ($ instanceof Ok) {
      let max = $[0].max;
      return max;
    } else {
      return 0;
    }
  }
  function has_alarm(metric, unit) {
    let $ = metric_scale(metric, unit);
    if ($ instanceof Ok && $[0].alarm instanceof Rising) {
      return true;
    } else {
      return false;
    }
  }
  function scale_warn(metric, unit) {
    let $ = metric_scale(metric, unit);
    if ($ instanceof Ok) {
      let $1 = $[0].alarm;
      if ($1 instanceof Rising) {
        let warn = $1.warn;
        return warn;
      } else {
        return 0;
      }
    } else {
      return 0;
    }
  }
  function scale_danger(metric, unit) {
    let $ = metric_scale(metric, unit);
    if ($ instanceof Ok) {
      let $1 = $[0].alarm;
      if ($1 instanceof Rising) {
        let danger = $1.danger;
        return danger;
      } else {
        return 0;
      }
    } else {
      return 0;
    }
  }
  function number_level(metric, unit, number) {
    let $ = metric_scale(metric, unit);
    if ($ instanceof Ok) {
      let $1 = $[0].alarm;
      if ($1 instanceof Quiet) {
        return "";
      } else {
        let warn = $1.warn;
        let danger = $1.danger;
        let $2 = number >= identity(danger);
        if ($2) {
          return "danger";
        } else {
          let $3 = number >= identity(warn);
          if ($3) {
            return "warn";
          } else {
            return "";
          }
        }
      }
    } else {
      return "";
    }
  }
  function alarm_metric(metric) {
    if (metric === "leak") {
      return true;
    } else if (metric === "alarm") {
      return true;
    } else {
      return false;
    }
  }
  function metric_level(present, metric, unit, has_flag, flag, has_number, number) {
    if (present) {
      if (has_flag) {
        let $ = flag && alarm_metric(metric);
        if ($) {
          return "danger";
        } else {
          return "";
        }
      } else {
        if (has_number) {
          return number_level(metric, unit, number);
        } else {
          return "";
        }
      }
    } else {
      return "";
    }
  }
  function metric_order() {
    return toList([
      "cpu_temperature_c",
      "cpu_used_pct",
      "memory_used_pct",
      "disk_used_pct",
      "load_1m",
      "battery_pct",
      "acceleration_ms2",
      "acceleration_x",
      "acceleration_y",
      "acceleration_z",
      "orientation_deg",
      "rotation_alpha",
      "rotation_beta",
      "rotation_gamma",
      "latitude",
      "longitude",
      "location_accuracy",
      "voice_level",
      "voice_transcript",
      "voice_clip"
    ]);
  }
  function index_of(loop$items, loop$wanted, loop$index) {
    while (true) {
      let items = loop$items;
      let wanted = loop$wanted;
      let index2 = loop$index;
      if (items instanceof Empty) {
        return new Error2(void 0);
      } else {
        let first2 = items.head;
        if (first2 === wanted) {
          return new Ok(index2);
        } else {
          let rest = items.tail;
          loop$items = rest;
          loop$wanted = wanted;
          loop$index = index2 + 1;
        }
      }
    }
  }
  function metric_position(metric) {
    let $ = index_of(metric_order(), metric, 0);
    if ($ instanceof Ok) {
      let index2 = $[0];
      return index2;
    } else {
      return length(metric_order());
    }
  }
  function then$(current, next) {
    if (current instanceof Eq) {
      return next();
    } else {
      return current;
    }
  }
  function shape_rank(shape) {
    if (shape === "number") {
      return 0;
    } else if (shape === "flag") {
      return 1;
    } else {
      return 2;
    }
  }
  function primary_rank(metric, primary) {
    let $ = metric === primary;
    if ($) {
      return 0;
    } else {
      return 1;
    }
  }
  function compare_metrics(left_metric, left_shape, right_metric, right_shape, kind) {
    let primary = get2(kind).metric;
    return to_int(
      then$(
        compare(
          primary_rank(left_metric, primary),
          primary_rank(right_metric, primary)
        ),
        () => {
          return then$(
            compare(shape_rank(left_shape), shape_rank(right_shape)),
            () => {
              return then$(
                compare(
                  metric_position(left_metric),
                  metric_position(right_metric)
                ),
                () => {
                  return compare3(left_metric, right_metric);
                }
              );
            }
          );
        }
      )
    );
  }
  function install2() {
    return install();
  }

  // entries/sensor-kinds.js
  install2();
})();
