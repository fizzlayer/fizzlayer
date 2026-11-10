"""HTTP calls from Home Assistant to a Fizzlayer server."""

from __future__ import annotations

import asyncio
import logging

from aiohttp import ClientError

from homeassistant.core import HomeAssistant
from homeassistant.helpers.aiohttp_client import async_get_clientsession

_LOGGER = logging.getLogger(__name__)


class FizzlayerConnectionError(Exception):
    """The Fizzlayer server could not be reached."""


async def post_json(
    hass: HomeAssistant,
    url: str,
    payload: dict,
    api_key: str | None = None,
    timeout: float = 30,
) -> dict:
    """POST JSON and return the object plus a `_status` code. The key is not logged."""
    session = async_get_clientsession(hass)
    headers = {"Content-Type": "application/json"}
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"
    try:
        async with asyncio.timeout(timeout):
            async with session.post(url, json=payload, headers=headers) as response:
                try:
                    data = await response.json(content_type=None)
                except (ClientError, ValueError, TypeError):
                    data = {}
                if not isinstance(data, dict):
                    data = {}
                data["_status"] = response.status
                return data
    except (ClientError, TimeoutError, asyncio.TimeoutError) as err:
        _LOGGER.debug("Fizzlayer request to %s failed: %s", url.split("?", 1)[0], type(err).__name__)
        raise FizzlayerConnectionError from err


def error_code(data: dict) -> str | None:
    """Read an error code from either the SQL shape or the HTTP error object."""
    error = data.get("error")
    if isinstance(error, str):
        return error
    if isinstance(error, dict):
        code = error.get("code")
        return code if isinstance(code, str) else None
    return None
