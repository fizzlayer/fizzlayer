import gleam/int
import gleam/string
import gleeunit/should
import kind.{type Ago, Days, Hours, JustNow, Minutes}

pub fn order_lists_every_category_test() {
  kind.order()
  |> should.equal([
    "water",
    "gas",
    "radio",
    "temperature",
    "pressure",
    "humidity",
    "sound",
    "phone",
    "custom",
  ])
}

pub fn known_kind_keeps_its_metric_and_colour_test() {
  let temperature = kind.get("temperature")
  temperature.label |> should.equal("Temperature")
  temperature.metric |> should.equal("temperature_c")
  temperature.unit |> should.equal("°C")
  temperature.color |> should.equal("#ff7b6b")
  temperature.icon |> should.equal("temperature-half")
  temperature.example |> should.equal("Kitchen temperature")
}

pub fn unknown_kind_uses_the_generic_sensor_test() {
  let unknown = kind.get("plasma")
  unknown.label |> should.equal("Sensor")
  unknown.metric |> should.equal("value")
  unknown.unit |> should.equal("")
  unknown.color |> should.equal("#a9eaf7")
  unknown.icon |> should.equal("sliders")
}

pub fn icon_art_matches_the_font_awesome_path_test() {
  kind.icon_width("temperature") |> should.equal(320)
  kind.icon_path("humidity")
  |> string_starts_with("M192 512C86 512")
}

pub fn metric_label_uses_the_known_name_or_a_title_test() {
  kind.metric_label("") |> should.equal("")
  kind.metric_label("cpu_temperature_c") |> should.equal("CPU temperature")
  kind.metric_label("custom_metric") |> should.equal("Custom metric")
  kind.metric_label("ABC_def") |> should.equal("ABC def")
}

pub fn format_value_spaces_units_except_percent_test() {
  kind.format_value("4.8", "°C") |> should.equal("4.8 °C")
  kind.format_value("48", "%") |> should.equal("48%")
  kind.format_value("12", "") |> should.equal("12")
}

pub fn format_boolean_names_leaks_and_alarms_test() {
  kind.format_boolean("leak", True) |> should.equal("Leak detected")
  kind.format_boolean("leak", False) |> should.equal("No leak")
  kind.format_boolean("alarm", True) |> should.equal("Alarm")
  kind.format_boolean("alarm", False) |> should.equal("Clear")
  kind.format_boolean("motion", True) |> should.equal("Yes")
  kind.format_boolean("motion", False) |> should.equal("No")
}

pub fn format_reading_prefers_clips_and_flags_test() {
  kind.format_reading(False, "temperature_c", "°C", False, False, "4")
  |> should.equal("Waiting for data")
  kind.format_reading(True, "voice_clip", "", True, True, "1")
  |> should.equal("Clip received")
  kind.format_reading(True, "leak", "", True, True, "true")
  |> should.equal("Leak detected")
  kind.format_reading(True, "temperature_c", "°C", False, False, "4.8")
  |> should.equal("4.8 °C")
}

pub fn ago_buckets_match_the_previous_rounding_test() {
  assert_ago(kind.describe_ago(44), JustNow)
  assert_ago(kind.describe_ago(-44), JustNow)
  assert_ago(kind.describe_ago(45), Minutes(1))
  assert_ago(kind.describe_ago(-90), Minutes(-1))
  assert_ago(kind.describe_ago(3599), Minutes(60))
  assert_ago(kind.describe_ago(3600), Hours(1))
  assert_ago(kind.describe_ago(-5400), Hours(-1))
  assert_ago(kind.describe_ago(86_399), Hours(24))
  assert_ago(kind.describe_ago(86_400), Days(1))
}

pub fn time_ago_asks_the_formatter_for_the_chosen_unit_test() {
  kind.time_ago(120, fn(unit, amount) { unit <> ":" <> int.to_string(amount) })
  |> should.equal("minute:2")
  kind.time_ago(10, fn(_unit, _amount) { "unused" })
  |> should.equal("just now")
}

pub fn scale_uses_known_ranges_then_percent_fallback_test() {
  let assert Ok(temperature) = kind.metric_scale("temperature_c", "°C")
  temperature.min |> should.equal(-20)
  temperature.max |> should.equal(50)
  kind.has_alarm("temperature_c", "°C") |> should.equal(False)

  let assert Ok(cpu) = kind.metric_scale("cpu_temperature_c", "°C")
  cpu.min |> should.equal(20)
  kind.scale_warn("cpu_temperature_c", "°C") |> should.equal(70)
  kind.scale_danger("cpu_temperature_c", "°C") |> should.equal(85)

  let assert Ok(signal) = kind.metric_scale("rssi_dbm", "dBm")
  signal.min |> should.equal(-110)
  signal.max |> should.equal(-30)

  let assert Ok(percent) = kind.metric_scale("custom_pct", "")
  percent.min |> should.equal(0)
  percent.max |> should.equal(100)
  kind.has_scale("level", "%") |> should.equal(True)
  kind.has_scale("notes", "") |> should.equal(False)
}

pub fn metric_level_warns_only_above_the_threshold_test() {
  kind.metric_level(False, "cpu_temperature_c", "°C", False, False, True, 90.0)
  |> should.equal("")
  kind.metric_level(True, "leak", "", True, True, False, 0.0)
  |> should.equal("danger")
  kind.metric_level(True, "leak", "", True, False, True, 1.0)
  |> should.equal("")
  kind.metric_level(True, "motion", "", True, True, False, 0.0)
  |> should.equal("")
  kind.metric_level(True, "cpu_temperature_c", "°C", False, False, True, 85.0)
  |> should.equal("danger")
  kind.metric_level(True, "cpu_temperature_c", "°C", False, False, True, 70.0)
  |> should.equal("warn")
  kind.metric_level(True, "cpu_temperature_c", "°C", False, False, True, 69.9)
  |> should.equal("")
  kind.metric_level(True, "temperature_c", "°C", False, False, True, 40.0)
  |> should.equal("")
  kind.metric_level(True, "notes", "", False, False, False, 0.0)
  |> should.equal("")
}

pub fn compare_metrics_puts_the_primary_metric_first_test() {
  kind.compare_metrics(
    "temperature_c",
    "number",
    "humidity_pct",
    "number",
    "temperature",
  )
  |> should.equal(-1)
  kind.compare_metrics("humidity_pct", "number", "leak", "flag", "water")
  |> should.equal(-1)
  kind.compare_metrics("note", "text", "leak", "flag", "water")
  |> should.equal(1)
  kind.compare_metrics("value", "text", "cpu_used_pct", "number", "custom")
  |> should.equal(-1)
  kind.compare_metrics(
    "cpu_used_pct",
    "number",
    "memory_used_pct",
    "number",
    "water",
  )
  |> should.equal(-1)
  kind.compare_metrics("alpha", "text", "zeta", "text", "water")
  |> should.equal(-1)
  kind.compare_metrics("cpu_used_pct", "number", "alpha", "number", "water")
  |> should.equal(-1)
  kind.compare_metrics(
    "humidity_pct",
    "number",
    "humidity_pct",
    "number",
    "water",
  )
  |> should.equal(0)
}

fn assert_ago(actual: Ago, expected: Ago) {
  actual |> should.equal(expected)
}

fn string_starts_with(value: String, prefix: String) -> Nil {
  string.starts_with(value, prefix) |> should.equal(True)
}
