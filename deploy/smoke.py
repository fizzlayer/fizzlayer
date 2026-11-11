#!/usr/bin/env python3
"""Sign up, create a sensor, and ingest one reading over HTTP, WebSocket, and MQTT."""

import base64
import json
import os
import socket
import struct
import sys
import time
import urllib.error
import urllib.request

API = os.environ.get("FIZZ_API", "http://localhost:8080").rstrip("/")
WORKER = os.environ.get("FIZZ_WORKER", "http://localhost:8081").rstrip("/")
MQTT_HOST = os.environ.get("FIZZ_MQTT_HOST", "127.0.0.1")
MQTT_PORT = int(os.environ.get("FIZZ_MQTT_PORT", "1883"))


class Jar(urllib.request.HTTPCookieProcessor):
    def __init__(self):
        super().__init__()
        self.raw = []

    def http_response(self, request, response):
        for header in response.headers.get_all("Set-Cookie") or []:
            self.raw.append(header.split(";", 1)[0])
        return response

    https_response = http_response

    def header(self):
        return "; ".join(self.raw)


jar = Jar()
opener = urllib.request.build_opener(jar)


def call(method, url, body=None, headers=None, timeout=20):
    data = None if body is None else json.dumps(body).encode()
    request = urllib.request.Request(url, data=data, method=method)
    request.add_header("Accept", "application/json")
    if body is not None:
        request.add_header("Content-Type", "application/json")
    if jar.header():
        request.add_header("Cookie", jar.header())
    for key, value in (headers or {}).items():
        request.add_header(key, value)
    try:
        with opener.open(request, timeout=timeout) as response:
            raw = response.read()
            return response.status, json.loads(raw) if raw else {}
    except urllib.error.HTTPError as error:
        raw = error.read()
        try:
            parsed = json.loads(raw) if raw else {}
        except json.JSONDecodeError:
            parsed = {"raw": raw.decode(errors="replace")}
        return error.code, parsed


def wait_status():
    deadline = time.time() + 180
    last = None
    while time.time() < deadline:
        try:
            status, body = call("GET", f"{API}/api/status")
        except Exception as error:
            last = str(error)
            time.sleep(2)
            continue
        last = body
        if status == 200 and body.get("database") == "connected":
            return body
        time.sleep(2)
    raise SystemExit(f"API did not connect: {last}")


def enc_str(value: str) -> bytes:
    raw = value.encode()
    return struct.pack("!H", len(raw)) + raw


def remaining(length: int) -> bytes:
    out = bytearray()
    while True:
        digit = length % 128
        length //= 128
        if length:
            digit |= 0x80
        out.append(digit)
        if not length:
            return bytes(out)


def mqtt_publish(sensor_id: str, key: str, payload: bytes):
    variable = enc_str("MQTT") + bytes([4, 0xC2, 0x00, 0x3C])
    body = variable + enc_str("fizz-smoke") + enc_str(sensor_id) + enc_str(key)
    packet = bytes([0x10]) + remaining(len(body)) + body
    topic = f"fizz/v1/{sensor_id}/readings"
    pub_body = enc_str(topic) + payload
    publish = bytes([0x30]) + remaining(len(pub_body)) + pub_body
    sock = socket.create_connection((MQTT_HOST, MQTT_PORT), 10)
    sock.settimeout(10)
    sock.sendall(packet)
    ack = sock.recv(4)
    if len(ack) < 4 or ack[0] != 0x20 or ack[3] != 0:
        raise SystemExit(f"MQTT CONNACK was {ack!r}")
    sock.sendall(publish)
    time.sleep(0.5)
    sock.close()


def ws_send(sock, text: str):
    payload = text.encode()
    mask = os.urandom(4)
    frame = bytearray([0x81])
    length = len(payload)
    if length < 126:
        frame.append(0x80 | length)
    else:
        frame.append(0x80 | 126)
        frame += struct.pack("!H", length)
    frame += mask
    frame += bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
    sock.sendall(frame)


def ws_publish(url: str, key: str, reading: dict):
    if "://" not in url:
        raise SystemExit(f"bad websocket url {url}")
    rest = url.split("://", 1)[1]
    host_port, _, path = rest.partition("/")
    path = "/" + path
    if ":" in host_port:
        host, port = host_port.rsplit(":", 1)
        port = int(port)
    else:
        host, port = host_port, 80
    sock = socket.create_connection((host, port), 10)
    nonce = base64.b64encode(os.urandom(16)).decode()
    request = (
        f"GET {path} HTTP/1.1\r\n"
        f"Host: {host}:{port}\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {nonce}\r\n"
        "Sec-WebSocket-Version: 13\r\n\r\n"
    )
    sock.sendall(request.encode())
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = sock.recv(4096)
        if not chunk:
            break
        data += chunk
    if b" 101 " not in data.split(b"\r\n", 1)[0]:
        raise SystemExit(f"websocket upgrade failed: {data[:200]!r}")
    ws_send(sock, json.dumps({"op": "auth", "key": key}))
    ws_send(sock, json.dumps({"op": "reading", **reading}))
    sock.settimeout(5)
    try:
        sock.recv(4096)
    except socket.timeout:
        pass
    sock.close()


def main():
    print("status", wait_status())
    email = f"smoke-{int(time.time())}@example.com"
    password = "local-smoke-pass"
    status, body = call(
        "POST",
        f"{API}/api/auth",
        {"action": "sign_up", "email": email, "password": password},
    )
    print("sign_up", status, {k: body.get(k) for k in ("ok", "error", "message", "confirm_email")})
    if status != 200 or not body.get("ok"):
        raise SystemExit("sign-up failed")
    if body.get("confirm_email"):
        raise SystemExit("sign-up is waiting for email confirmation; set MAILER_AUTOCONFIRM=true")
    status, created = call(
        "POST",
        f"{API}/api/sensors",
        {"kind": "temperature", "name": "Smoke sensor", "mode": "api"},
    )
    print("sensor", status, created.get("error"), created.get("message"))
    if status not in (200, 201) or "api_key" not in created:
        raise SystemExit(f"create sensor failed: {created}")
    sensor_id = created["sensor"]["id"]
    key = created["api_key"]

    def ingest(event_id, value):
        status, body = call(
            "POST",
            f"{API}/api/ingest",
            {
                "sensor_id": sensor_id,
                "event_id": event_id,
                "metrics": {"temperature_c": value},
            },
            headers={"Authorization": f"Bearer {key}"},
        )
        print("ingest", event_id, status, body.get("error") or "accepted")
        if status not in (200, 201, 202) or body.get("error"):
            raise SystemExit(f"ingest {event_id} failed: {body}")

    ingest("http-smoke", 21.5)
    stream_status, stream = call("GET", f"{API}/api/stream")
    print("stream", stream_status, stream)
    if not stream.get("enabled"):
        raise SystemExit("streaming is not enabled")
    ws_url = stream["websocket_url"]
    if ws_url.startswith("ws://localhost"):
        ws_url = ws_url.replace("ws://localhost", "ws://127.0.0.1", 1)
    ws_publish(
        ws_url,
        key,
        {"sensor_id": sensor_id, "event_id": "ws-smoke", "metrics": {"temperature_c": 22.5}},
    )
    print("websocket sent")
    mqtt_publish(
        sensor_id,
        key,
        json.dumps(
            {"sensor_id": sensor_id, "event_id": "mqtt-smoke", "metrics": {"temperature_c": 23.5}}
        ).encode(),
    )
    print("mqtt sent")
    time.sleep(1)
    status, readings = call("GET", f"{API}/api/readings?sensor_id={sensor_id}&limit=20")
    print("readings", status)
    blob = json.dumps(readings)
    for event_id in ("http-smoke", "ws-smoke", "mqtt-smoke"):
        if event_id not in blob:
            raise SystemExit(f"missing {event_id} in {blob[:800]}")
        print("saw", event_id)
    health = urllib.request.urlopen(f"{WORKER}/health", timeout=10)
    print("worker", health.status, health.read().decode())
    print("ok")


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception as error:
        print(f"smoke failed: {error}", file=sys.stderr)
        raise
