"""Throttle, batch, buffer, and revocation rules for the outbound queue."""

from custom_components.fizzlayer.push import (
    PushQueue,
    Reading,
    ingest_body,
    split_results,
)


def reading(entity="sensor.rack_temp", value=21.0, event="st:1"):
    return Reading(entity, "sensor-id", event, "temperature_c", value, "2026-11-04T00:00:00+00:00")


def test_changes_are_throttled_and_heartbeats_resend_the_same_value():
    queue = PushQueue(heartbeat_seconds=30, min_interval=10)
    assert queue.consider(reading(value=21), 0) == "queued"
    queue.ack(queue.take_batch(0), 0)

    assert queue.consider(reading(value=22, event="st:2"), 5) == "coalesce"
    assert queue.take_batch(5) == []
    sent = queue.take_batch(10)
    assert [item.value for item in sent] == [22]
    queue.ack(sent, 10)

    assert queue.consider(reading(value=22, event="hb:1"), 20) == "drop"
    assert queue.consider(reading(value=22, event="hb:2"), 40) == "queued"


def test_failures_are_buffered_and_a_revoked_key_drops_them():
    queue = PushQueue(buffer_limit=2)
    first = reading(event="a")
    second = reading(entity="sensor.other", event="b", value=1)
    third = reading(entity="binary_sensor.door", event="c", value=True)
    queue.requeue([first, second, third])
    assert [item.event_id for item in queue.buffer] == ["a", "b"]

    stored, retry = split_results(
        [first, second],
        [{"id": "1", "source": "homeassistant"}, {"error": "rate_limited"}],
    )
    assert stored == [first] and retry == [second]
    stored, retry = split_results(
        [first, second], [{"error": "paused"}, {"error": "invalid_reading"}]
    )
    assert stored == [] and retry == []

    body = ingest_body([first])
    assert body["readings"][0]["metrics"] == {"temperature_c": 21.0}
    queue.mark_revoked()
    assert queue.revoked and queue.buffer == [] and queue.consider(first, 0) == "revoked"


def test_snapshot_round_trip_keeps_unsent_readings():
    queue = PushQueue()
    queue.requeue([reading(value=7, event="offline")])
    restored = PushQueue()
    restored.restore(queue.snapshot())
    assert restored.buffer[0].value == 7
    empty = PushQueue()
    empty.restore([{"event_id": "bad"}])
    assert empty.buffer == []
