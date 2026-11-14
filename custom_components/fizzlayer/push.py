"""Decide which readings to send, batch them, and hold them while Fizzlayer is unreachable.

The queue is deliberately free of Home Assistant so the timing rules can be tested on
their own. The integration feeds it state changes and asks it to flush.
"""

from __future__ import annotations

from dataclasses import dataclass, field

from .const import HEARTBEAT_SECONDS, MAX_BATCH, MAX_BUFFER, MIN_CHANGE_SECONDS


@dataclass(frozen=True)
class Reading:
    entity_id: str
    sensor_id: str
    event_id: str
    metric: str
    value: float | bool
    observed_at: str


@dataclass
class PushQueue:
    """Latest value per entity, plus a buffer of readings that have not been stored yet."""

    heartbeat_seconds: float = HEARTBEAT_SECONDS
    min_interval: float = MIN_CHANGE_SECONDS
    batch_size: int = MAX_BATCH
    buffer_limit: int = MAX_BUFFER
    last_sent: dict[str, tuple[float, float | bool]] = field(default_factory=dict)
    pending: dict[str, Reading] = field(default_factory=dict)
    buffer: list[Reading] = field(default_factory=list)
    revoked: bool = False

    def consider(
        self,
        reading: Reading,
        now: float,
        *,
        heartbeat: bool = False,
    ) -> str:
        """Queue a reading, or drop it when it is too soon and unchanged."""
        if self.revoked:
            return "revoked"
        last = self.last_sent.get(reading.entity_id)
        if last is not None:
            last_at, last_value = last
            elapsed = now - last_at
            changed = last_value != reading.value
            if changed and elapsed < self.min_interval:
                self.pending[reading.entity_id] = reading
                return "coalesce"
            if not changed and elapsed < self.heartbeat_seconds:
                return "drop"
        self.pending[reading.entity_id] = reading
        return "queued"

    def take_batch(self, now: float) -> list[Reading]:
        """Retries first, then values whose throttle window has opened."""
        batch: list[Reading] = []
        while self.buffer and len(batch) < self.batch_size:
            batch.append(self.buffer.pop(0))
        for entity_id in list(self.pending):
            if len(batch) >= self.batch_size:
                break
            reading = self.pending[entity_id]
            last = self.last_sent.get(entity_id)
            if last is not None:
                last_at, last_value = last
                elapsed = now - last_at
                if last_value != reading.value and elapsed < self.min_interval:
                    continue
                if last_value == reading.value and elapsed < self.heartbeat_seconds:
                    self.pending.pop(entity_id, None)
                    continue
            batch.append(self.pending.pop(entity_id))
        return batch

    def ack(self, readings: list[Reading], now: float) -> None:
        for reading in readings:
            self.last_sent[reading.entity_id] = (now, reading.value)
            self.pending.pop(reading.entity_id, None)

    def requeue(self, readings: list[Reading]) -> None:
        self.buffer = (readings + self.buffer)[: self.buffer_limit]

    def mark_revoked(self) -> None:
        self.revoked = True
        self.pending.clear()
        self.buffer.clear()

    def snapshot(self) -> list[dict]:
        return [_reading_dict(reading) for reading in self.buffer]

    def restore(self, items: list[dict]) -> None:
        restored: list[Reading] = []
        for item in items[: self.buffer_limit]:
            try:
                restored.append(
                    Reading(
                        entity_id=item["entity_id"],
                        sensor_id=item["sensor_id"],
                        event_id=item["event_id"],
                        metric=item["metric"],
                        value=item["value"],
                        observed_at=item["observed_at"],
                    )
                )
            except (KeyError, TypeError):
                continue
        self.buffer = restored


def _reading_dict(reading: Reading) -> dict:
    return {
        "entity_id": reading.entity_id,
        "sensor_id": reading.sensor_id,
        "event_id": reading.event_id,
        "metric": reading.metric,
        "value": reading.value,
        "observed_at": reading.observed_at,
    }


def ingest_body(readings: list[Reading]) -> dict:
    """The body of POST /api/ingest. One event is one metric, matching a Fizzlayer sensor."""
    return {
        "readings": [
            {
                "sensor_id": reading.sensor_id,
                "event_id": reading.event_id,
                "observed_at": reading.observed_at,
                "metrics": {reading.metric: reading.value},
            }
            for reading in readings
        ]
    }


def split_results(
    readings: list[Reading], results: list[dict] | None
) -> tuple[list[Reading], list[Reading]]:
    """Split a batch into stored readings and readings that should be retried.

    A paused sensor or a value the server rejected is dropped. Rate limits and
    outages stay in the buffer. A result list shorter than the batch retries the rest.
    """
    stored: list[Reading] = []
    retry: list[Reading] = []
    outcomes = results or []
    for index, reading in enumerate(readings):
        if index >= len(outcomes):
            retry.append(reading)
            continue
        error = outcomes[index].get("error")
        if error is None:
            stored.append(reading)
        elif error in {"invalid_reading", "paused", "unauthorized", "invalid_request"}:
            continue
        else:
            retry.append(reading)
    return stored, retry
