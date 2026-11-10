"""Fizzlayer pushes Home Assistant state out to a Fizzlayer workspace.

The install is not opened to the internet. State changes are throttled and batched
into the same POST /api/ingest the device CLI uses, and a heartbeat resends the
last value so a silence alert can tell a quiet sensor from a dead one.
"""

from __future__ import annotations

import asyncio
import logging
import time
from datetime import datetime, timezone

from homeassistant.config_entries import ConfigEntry
from homeassistant.const import EVENT_STATE_CHANGED
from homeassistant.core import Event, HomeAssistant, callback
from homeassistant.helpers.storage import Store

from .client import FizzlayerConnectionError, error_code, post_json
from .config_flow import sync_selected
from .const import DOMAIN, FLUSH_SECONDS, HEARTBEAT_SECONDS, INTEGRATION_VERSION
from .mapping import EntityPlan, convert_value
from .push import PushQueue, Reading, ingest_body, split_results

_LOGGER = logging.getLogger(__name__)
PLATFORMS: list[str] = []
STORAGE_VERSION = 1


async def async_setup_entry(hass: HomeAssistant, entry: ConfigEntry) -> bool:
    _LOGGER.info("Fizzlayer integration %s is starting", INTEGRATION_VERSION)
    runtime = FizzlayerRuntime(hass, entry)
    await runtime.async_start()
    hass.data.setdefault(DOMAIN, {})[entry.entry_id] = runtime
    entry.async_on_unload(entry.add_update_listener(_reload))
    return True


async def async_unload_entry(hass: HomeAssistant, entry: ConfigEntry) -> bool:
    runtime = hass.data.get(DOMAIN, {}).pop(entry.entry_id, None)
    if runtime is not None:
        await runtime.async_stop()
    return True


async def async_remove_entry(hass: HomeAssistant, entry: ConfigEntry) -> None:
    """Revoke the device key when the user removes the integration."""
    api_key = entry.data.get("api_key")
    base_url = entry.data.get("base_url")
    if not api_key or not base_url:
        return
    try:
        await post_json(
            hass,
            f"{base_url}/api/devices",
            {"action": "ha_revoke"},
            api_key=api_key,
        )
    except FizzlayerConnectionError:
        _LOGGER.warning("Fizzlayer could not be reached to revoke the connection")


async def _reload(hass: HomeAssistant, entry: ConfigEntry) -> None:
    await hass.config_entries.async_reload(entry.entry_id)


class FizzlayerRuntime:
    """Listens for state changes and flushes them to Fizzlayer."""

    def __init__(self, hass: HomeAssistant, entry: ConfigEntry) -> None:
        self.hass = hass
        self.entry = entry
        self.queue = PushQueue()
        self._sensors: dict[str, dict] = dict(entry.options.get("sensors") or {})
        self._unsub = None
        self._task: asyncio.Task | None = None
        self._store = Store(hass, STORAGE_VERSION, f"fizzlayer.{entry.entry_id}")

    async def async_start(self) -> None:
        stored = await self._store.async_load()
        if isinstance(stored, dict):
            self.queue.restore(stored.get("buffer") or [])
        await self._refresh()
        self._enqueue_current(heartbeat=True)
        self._unsub = self.hass.bus.async_listen(EVENT_STATE_CHANGED, self._on_state)
        self._task = self.hass.async_create_task(self._run())

    async def async_stop(self) -> None:
        if self._unsub is not None:
            self._unsub()
            self._unsub = None
        if self._task is not None:
            self._task.cancel()
            self._task = None
        await self._persist()

    async def _refresh(self) -> None:
        entity_ids = list(self.entry.options.get("entities") or self._sensors)
        if not entity_ids:
            return
        try:
            synced = await sync_selected(
                self.hass,
                self.entry.data["base_url"],
                self.entry.data["api_key"],
                entity_ids,
                False,
            )
        except FizzlayerConnectionError:
            _LOGGER.debug("Fizzlayer sync skipped; readings stay buffered")
            return
        if error_code(synced) == "unauthorized" or synced.get("_status") == 401:
            await self._revoked()
            return
        sensors = synced.get("sensors")
        if not isinstance(sensors, list):
            return
        mapped = {
            item["entity_id"]: {
                "sensor_id": item["sensor_id"],
                "metric": item["metric"],
                "boolean": bool(item.get("boolean")),
                "device_class": item.get("device_class"),
                "unit": item.get("unit"),
            }
            for item in sensors
            if item.get("entity_id") and item.get("sensor_id") and item.get("metric")
        }
        if mapped:
            self._sensors = mapped

    def _plan(self, meta: dict) -> EntityPlan:
        return EntityPlan(
            kind="custom",
            metric=meta["metric"],
            unit=meta.get("unit"),
            boolean=bool(meta.get("boolean")),
            device_class=meta.get("device_class"),
            canonical=bool(meta.get("device_class")) and not meta.get("boolean"),
        )

    def _enqueue_current(self, *, heartbeat: bool) -> None:
        now = time.monotonic()
        for entity_id, meta in self._sensors.items():
            state = self.hass.states.get(entity_id)
            if state is None:
                continue
            self._enqueue(
                entity_id,
                meta,
                state.state,
                state.attributes.get("unit_of_measurement"),
                state.last_updated,
                heartbeat,
                now,
            )

    def _enqueue(
        self,
        entity_id: str,
        meta: dict,
        raw: str,
        unit: str | None,
        observed: datetime,
        heartbeat: bool,
        now: float,
    ) -> None:
        plan = self._plan(meta)
        value = convert_value(plan, raw, unit)
        if value is None:
            return
        # Heartbeat ids change with the clock, not with last_updated. Reusing the
        # state's timestamp would be idempotent and would not reset a silence alert.
        if heartbeat:
            stamp = str(int(time.time()) // HEARTBEAT_SECONDS)
            observed_at = datetime.now(timezone.utc).isoformat()
            kind = "hb"
        else:
            stamp = observed.isoformat()
            observed_at = observed.isoformat()
            kind = "st"
        self.queue.consider(
            Reading(
                entity_id=entity_id,
                sensor_id=meta["sensor_id"],
                event_id=f"{kind}:{entity_id}:{stamp}"[:128],
                metric=meta["metric"],
                value=value,
                observed_at=observed_at,
            ),
            now,
            heartbeat=heartbeat,
        )

    @callback
    def _on_state(self, event: Event) -> None:
        entity_id = event.data.get("entity_id")
        meta = self._sensors.get(entity_id)
        new_state = event.data.get("new_state")
        if meta is None or new_state is None:
            return
        self._enqueue(
            entity_id,
            meta,
            new_state.state,
            new_state.attributes.get("unit_of_measurement"),
            new_state.last_updated,
            False,
            time.monotonic(),
        )

    async def _run(self) -> None:
        try:
            while not self.queue.revoked:
                await asyncio.sleep(FLUSH_SECONDS)
                self._enqueue_current(heartbeat=True)
                await self._flush()
        except asyncio.CancelledError:
            raise

    async def _flush(self) -> None:
        if self.queue.revoked:
            return
        batch = self.queue.take_batch(time.monotonic())
        if not batch:
            return
        try:
            data = await post_json(
                self.hass,
                f"{self.entry.data['base_url']}/api/ingest",
                ingest_body(batch),
                api_key=self.entry.data["api_key"],
            )
        except FizzlayerConnectionError:
            self.queue.requeue(batch)
            await self._persist()
            return
        if data.get("_status") == 401 or error_code(data) == "unauthorized":
            await self._revoked()
            return
        stored, retry = split_results(batch, data.get("results") if isinstance(data.get("results"), list) else None)
        self.queue.ack(stored, time.monotonic())
        if retry:
            self.queue.requeue(retry)
        await self._persist()

    async def _revoked(self) -> None:
        self.queue.mark_revoked()
        await self._store.async_remove()
        _LOGGER.error("Fizzlayer rejected the connection key; link the install again")
        self.entry.async_start_reauth(self.hass)

    async def _persist(self) -> None:
        if self.queue.revoked:
            return
        await self._store.async_save({"buffer": self.queue.snapshot()})
