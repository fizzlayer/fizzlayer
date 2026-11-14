"""Map Home Assistant entities onto Fizzlayer sensors and canonical units.

The server stores the same mapping. This module only converts the number so the
value posted to Fizzlayer is already in that unit. When a unit cannot be
converted, the entity is shared as a custom sensor and the original unit is kept.
"""

from __future__ import annotations

from dataclasses import dataclass
from urllib.parse import urlparse

UNAVAILABLE = frozenset({"unknown", "unavailable", "none", ""})

_TEMPERATURE = {"°c", "c", "celsius", "ºc"}
_FAHRENHEIT = {"°f", "f", "fahrenheit", "ºf"}
_KELVIN = {"k", "kelvin"}
_PRESSURE_KPA = {
    "kpa": 1.0,
    "pa": 0.001,
    "hpa": 0.1,
    "mbar": 0.1,
    "bar": 100.0,
    "psi": 6.894757,
    "inhg": 3.386389,
    "mmhg": 0.133322,
}
_POWER_W = {"w": 1.0, "watt": 1.0, "watts": 1.0, "kw": 1000.0, "mw": 1_000_000.0}


@dataclass(frozen=True)
class EntityPlan:
    """How one entity is stored and which metric a reading uses."""

    kind: str
    metric: str
    unit: str | None
    boolean: bool
    device_class: str | None
    canonical: bool


def normalize_base_url(url: str) -> str:
    """Accept the cloud origin or an http localhost for a self-hosted install."""
    cleaned = url.strip().rstrip("/")
    parsed = urlparse(cleaned)
    host = (parsed.hostname or "").lower()
    if (
        parsed.scheme not in {"https", "http"}
        or not parsed.netloc
        or parsed.username
        or parsed.password
        or len(cleaned) > 200
        or " " in cleaned
    ):
        raise ValueError("invalid url")
    if parsed.scheme == "http" and host not in {"localhost", "127.0.0.1"}:
        raise ValueError("invalid url")
    return cleaned


def _clean_class(device_class: str | None) -> str | None:
    if not device_class:
        return None
    text = device_class.strip().lower()
    if not text or len(text) > 40 or not text[0].isalpha():
        return None
    if any(not (char.islower() or char.isdigit() or char == "_") for char in text):
        return None
    return text


def _clean_unit(unit: str | None) -> str | None:
    if unit is None:
        return None
    text = unit.strip()
    if not text or len(text) > 24 or any(ord(char) < 32 for char in text):
        return None
    return text


def plan_entity(entity_id: str, device_class: str | None, unit: str | None) -> EntityPlan | None:
    """Return the Fizzlayer sensor shape for an entity, or None if it cannot be shared."""
    if entity_id.count(".") != 1:
        return None
    domain, object_id = entity_id.split(".", 1)
    if domain not in {"sensor", "binary_sensor"} or not object_id:
        return None
    if any(not (char.islower() or char.isdigit() or char == "_") for char in object_id):
        return None
    device = _clean_class(device_class)
    if domain == "binary_sensor":
        if device == "moisture":
            return EntityPlan("water", "leak", None, True, device, True)
        if device in {"gas", "carbon_monoxide", "safety"}:
            return EntityPlan("gas", "alarm", None, True, device, True)
        if device in {"door", "window", "opening", "garage_door", "lock"}:
            return EntityPlan("custom", "open", None, True, device, True)
        if device in {"motion", "occupancy", "presence", "moving"}:
            return EntityPlan("custom", "occupied", None, True, device, True)
        return EntityPlan("custom", "on", None, True, device, True)
    canonical = _canonical(device, unit)
    if canonical is not None:
        kind, metric, stored_unit = canonical
        return EntityPlan(kind, metric, stored_unit, False, device, True)
    return EntityPlan("custom", "value", _clean_unit(unit), False, None, False)


def _canonical(device_class: str | None, unit: str | None) -> tuple[str, str, str] | None:
    """Known device classes whose unit we can normalize. None keeps the entity custom."""
    key = (unit or "").strip().lower().replace(" ", "")
    if device_class == "temperature" and (
        key in _TEMPERATURE or key in _FAHRENHEIT or key in _KELVIN or key == ""
    ):
        return ("temperature", "temperature_c", "°C")
    if device_class == "humidity" and key in {"%", "percent", "%rh", ""}:
        return ("humidity", "humidity_pct", "%")
    if device_class in {"pressure", "atmospheric_pressure"} and (key in _PRESSURE_KPA or key == ""):
        return ("pressure", "pressure_kpa", "kPa")
    if device_class in {"gas", "carbon_monoxide"} and key in {"ppm", ""}:
        return ("gas", "concentration_ppm", "ppm")
    if device_class == "sound_pressure" and key in {"db", "dba", ""}:
        return ("sound", "sound_db", "dB")
    if device_class == "power" and key in _POWER_W:
        return ("custom", "power_w", "W")
    if device_class == "energy" and key in {"kwh", "wh"}:
        return ("custom", "energy_kwh", "kWh")
    if device_class == "battery" and key in {"%", "percent", ""}:
        return ("custom", "battery_pct", "%")
    if device_class == "current" and key in {"a", "ma"}:
        return ("custom", "current_a", "A")
    if device_class == "voltage" and key in {"v", "mv"}:
        return ("custom", "voltage_v", "V")
    if device_class == "signal_strength" and key in {"dbm", ""}:
        return ("custom", "signal_dbm", "dBm")
    return None


def convert_value(plan: EntityPlan, raw: str | None, unit: str | None) -> float | bool | None:
    """Convert a state string into the value Fizzlayer expects, or None to skip it."""
    if raw is None:
        return None
    text = str(raw).strip().lower()
    if text in UNAVAILABLE:
        return None
    if plan.boolean:
        if text == "on":
            return True
        if text == "off":
            return False
        return None
    try:
        number = float(text)
    except ValueError:
        return None
    if not plan.canonical:
        return number
    key = (unit or "").strip().lower().replace(" ", "")
    device = plan.device_class
    if device == "temperature":
        if key in _FAHRENHEIT:
            number = (number - 32) * 5 / 9
        elif key in _KELVIN:
            number = number - 273.15
        return round(number, 2)
    if device in {"pressure", "atmospheric_pressure"}:
        return round(number * _PRESSURE_KPA.get(key, 1.0), 3)
    if device == "power":
        return round(number * _POWER_W.get(key, 1.0), 3)
    if device == "energy" and key == "wh":
        return round(number / 1000, 6)
    if device == "current" and key == "ma":
        return round(number / 1000, 6)
    if device == "voltage" and key == "mv":
        return round(number / 1000, 6)
    return round(number, 3)
