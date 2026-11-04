"""Unit conversions and entity plans, without Home Assistant running."""

import pytest

from custom_components.fizzlayer.mapping import convert_value, normalize_base_url, plan_entity


def test_temperature_humidity_power_and_door_defaults():
    temp = plan_entity("sensor.rack_temp", "temperature", "°F")
    assert temp is not None and temp.metric == "temperature_c" and temp.canonical
    assert convert_value(temp, "77", "°F") == 25.0
    assert convert_value(temp, "20", "°C") == 20.0

    humidity = plan_entity("sensor.rack_humidity", "humidity", "%")
    assert humidity is not None and humidity.kind == "humidity"
    assert convert_value(humidity, "48", "%") == 48.0

    power = plan_entity("sensor.ups_power", "power", "kW")
    assert power is not None and power.metric == "power_w" and power.unit == "W"
    assert convert_value(power, "0.18", "kW") == 180.0

    pressure = plan_entity("sensor.room_pressure", "pressure", "hPa")
    assert pressure is not None and pressure.unit == "kPa"
    assert convert_value(pressure, "1013", "hPa") == 101.3

    door = plan_entity("binary_sensor.closet_door", "door", None)
    assert door is not None and door.boolean and door.metric == "open"
    assert convert_value(door, "on", None) is True
    assert convert_value(door, "off", None) is False

    leak = plan_entity("binary_sensor.floor_leak", "moisture", None)
    assert leak is not None and leak.kind == "water" and leak.metric == "leak"


def test_unknown_unit_stays_custom_and_unavailable_is_skipped():
    weird = plan_entity("sensor.rack_temp", "temperature", "furlongs")
    assert weird is not None and not weird.canonical and weird.metric == "value"
    assert convert_value(weird, "12", "furlongs") == 12.0

    temp = plan_entity("sensor.rack_temp", "temperature", "°C")
    assert convert_value(temp, "unavailable", "°C") is None
    assert convert_value(temp, "unknown", "°C") is None
    assert plan_entity("light.lamp", None, None) is None
    assert plan_entity("sensor.bad-name", "temperature", "°C") is None


def test_base_url_allows_cloud_and_localhost_only():
    assert normalize_base_url("https://fizzlayer.com/") == "https://fizzlayer.com"
    assert normalize_base_url("http://127.0.0.1:3000") == "http://127.0.0.1:3000"
    with pytest.raises(ValueError):
        normalize_base_url("http://fizz.example")
    with pytest.raises(ValueError):
        normalize_base_url("https://user:pass@fizzlayer.com")
