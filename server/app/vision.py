"""Vision provider abstraction.

Supports four modes (set via env var VISION_PROVIDER):

  zen     — OpenCode Zen (default)         — paid, fast, multimodal
  gemini  — Google Gemini Free Tier        — free, requires GEMINI_API_KEY
  ollama  — Local Ollama (your laptop GPU) — free, fully offline
  mock    — No real vision; returns a stub
"""

from __future__ import annotations

import base64
import logging
import os
import re
import time

import httpx

log = logging.getLogger("xsight.vision")

VISION_PROVIDER = os.getenv("VISION_PROVIDER", "local").lower()

# OpenCode Zen
ZEN_BASE_URL = os.getenv("ZEN_BASE_URL", "https://opencode.ai/zen/v1")
ZEN_API_KEY = os.getenv("ZEN_API_KEY", "")
ZEN_VISION_MODEL = os.getenv("ZEN_VISION_MODEL", "gemini-3-flash")

# Local OpenAI-compatible gateway (e.g. http://localhost:20128/v1)
LOCAL_BASE_URL = os.getenv("LOCAL_BASE_URL", "")
LOCAL_API_KEY = os.getenv("LOCAL_API_KEY", "")
LOCAL_VISION_MODEL = os.getenv("LOCAL_VISION_MODEL", "gh/gpt-4o")

# Google Gemini (free tier — https://aistudio.google.com/app/apikey)
GEMINI_API_KEY = os.getenv("GEMINI_API_KEY", "")
GEMINI_MODEL = os.getenv("GEMINI_MODEL", "gemini-2.0-flash")
GEMINI_BASE_URL = os.getenv(
    "GEMINI_BASE_URL", "https://generativelanguage.googleapis.com/v1beta"
)

# Ollama (local — https://ollama.com)
OLLAMA_BASE_URL = os.getenv("OLLAMA_BASE_URL", "http://localhost:11434")
OLLAMA_MODEL = os.getenv("OLLAMA_VISION_MODEL", "qwen2.5vl:3b")
# How long Ollama keeps the model loaded after a request. "30m" or "-1" (forever).
OLLAMA_KEEP_ALIVE = os.getenv("OLLAMA_KEEP_ALIVE", "-1")

# Generation tuning. Smaller num_ctx + num_predict = faster.
OLLAMA_NUM_CTX = int(os.getenv("OLLAMA_NUM_CTX", "1536"))
OLLAMA_NUM_PREDICT = int(os.getenv("OLLAMA_NUM_PREDICT", "80"))
# 0 = let Ollama auto-pick; set explicitly when you want full GPU offload.
OLLAMA_NUM_GPU = int(os.getenv("OLLAMA_NUM_GPU", "0") or 0)
OLLAMA_NUM_THREAD = int(os.getenv("OLLAMA_NUM_THREAD", "0") or 0)

# Per-request timeout for vision providers (seconds).
VISION_TIMEOUT = float(os.getenv("VISION_TIMEOUT", "120"))


class VisionError(Exception):
    """Raised when a vision provider fails."""


def _truncate(text: str, n: int = 240) -> str:
    if not text:
        return ""
    return text if len(text) <= n else text[:n] + f"... <{len(text)} chars>"


async def describe_image(image_b64: str, prompt: str) -> tuple[str, str]:
    """Return (description, model_id) using the configured provider.

    Tries the configured provider, then falls back through the chain on
    auth/credit/connection errors:
        local -> zen -> gemini -> ollama -> mock.
    """
    requested = VISION_PROVIDER
    chain: list[str] = []

    # Build the fallback chain starting at the requested provider.
    order = ["local", "zen", "gemini", "ollama"]
    if requested in order:
        idx = order.index(requested)
        chain = order[idx:] + order[:idx]
    else:
        chain = [requested]

    last_err: VisionError | None = None
    for provider in chain:
        # Skip providers that obviously aren't configured.
        # zen public free works without API key
        if provider == "gemini" and not GEMINI_API_KEY:
            continue
        if provider == "local" and not (LOCAL_BASE_URL and LOCAL_API_KEY):
            continue
        try:
            log.info("[vision] trying provider=%s", provider)
            if provider == "local":
                return await _local_vision(image_b64, prompt)
            if provider == "zen":
                return await _zen_vision(image_b64, prompt)
            if provider == "gemini":
                return await _gemini_vision(image_b64, prompt)
            if provider == "ollama":
                return await _ollama_vision(image_b64, prompt)
        except VisionError as e:
            log.warning("[vision] %s failed: %s — trying next provider", provider, e)
            last_err = e
            continue

    if last_err is not None:
        raise last_err
    return (
        "Vision unavailable (no provider configured).",
        "mock",
    )


async def _local_vision(image_b64: str, prompt: str) -> tuple[str, str]:
    """OpenAI-compatible local gateway (e.g. http://localhost:20128/v1).

    Uses the standard chat.completions API with multimodal `image_url` parts.
    """
    if not LOCAL_BASE_URL:
        raise VisionError("LOCAL_BASE_URL missing")
    if not LOCAL_API_KEY:
        raise VisionError("LOCAL_API_KEY missing")
    body = {
        "model": LOCAL_VISION_MODEL,
        "messages": [
            {
                "role": "user",
                "content": [
                    {"type": "text", "text": prompt},
                    {
                        "type": "image_url",
                        "image_url": {"url": f"data:image/jpeg;base64,{image_b64}"},
                    },
                ],
            }
        ],
        "max_tokens": 200,
        "stream": False,
    }
    log.debug("[vision/local] -> %s model=%s", LOCAL_BASE_URL, LOCAL_VISION_MODEL)
    try:
        async with httpx.AsyncClient(timeout=VISION_TIMEOUT) as client:
            r = await client.post(
                f"{LOCAL_BASE_URL.rstrip('/')}/chat/completions",
                headers={
                    "Authorization": f"Bearer {LOCAL_API_KEY}",
                    "Content-Type": "application/json",
                },
                json=body,
            )
    except httpx.HTTPError as e:
        raise VisionError(
            f"Local gateway unreachable at {LOCAL_BASE_URL}: {e}"
        ) from e
    log.debug("[vision/local] <- status=%s len=%d", r.status_code, len(r.text))
    if r.status_code >= 400:
        raise VisionError(
            f"Local gateway error {r.status_code}: {_truncate(r.text)}"
        )
    data = _parse_openai_response(r.text)
    text = _extract_openai_content(data)
    if not text:
        raise VisionError(
            f"Empty content from local gateway. Raw: {_truncate(r.text)}"
        )
    return text.strip(), f"local/{LOCAL_VISION_MODEL}"


def _parse_openai_response(text: str) -> dict[str, object]:
    """Parse a chat.completions response, ignoring trailing SSE artifacts.

    Some OpenAI-compatible gateways append `data: [DONE]\\n` after a
    non-stream JSON body. We keep only the first JSON object.
    """
    import json as _json

    text = text.strip()
    # Strip trailing "data: [DONE]" or extra concatenated bodies.
    decoder = _json.JSONDecoder()
    try:
        obj, _idx = decoder.raw_decode(text)
        return obj
    except _json.JSONDecodeError:
        # Last-resort: take the first {...} balance.
        depth = 0
        start = -1
        for i, ch in enumerate(text):
            if ch == "{":
                if depth == 0:
                    start = i
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0 and start >= 0:
                    try:
                        return _json.loads(text[start : i + 1])
                    except _json.JSONDecodeError:
                        continue
        raise VisionError(f"Invalid JSON from gateway: {_truncate(text)}")


def _extract_openai_content(data: dict[str, object]) -> str:
    """Pull the text out of a chat.completions response, tolerating shapes."""
    try:
        choices = data["choices"]
    except KeyError:
        return ""
    if not isinstance(choices, list) or not choices:
        return ""
    msg = choices[0].get("message") if isinstance(choices[0], dict) else None
    if not isinstance(msg, dict):
        return ""
    content = msg.get("content")
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for p in content:
            if isinstance(p, dict):
                t = p.get("text") or p.get("content") or ""
                if t:
                    parts.append(t)
        return "".join(parts)
    return ""


async def _zen_vision(image_b64: str, prompt: str) -> tuple[str, str]:
    body = {
        "model": ZEN_VISION_MODEL,
        "messages": [
            {
                "role": "user",
                "content": [
                    {"type": "text", "text": prompt},
                    {
                        "type": "image_url",
                        "image_url": {"url": f"data:image/jpeg;base64,{image_b64}"},
                    },
                ],
            }
        ],
        "max_tokens": 200,
    }
    log.debug("[vision/zen] -> %s model=%s", ZEN_BASE_URL, ZEN_VISION_MODEL)
    headers = {"Content-Type": "application/json"}
    if ZEN_API_KEY:
        headers["Authorization"] = f"Bearer {ZEN_API_KEY}"
    async with httpx.AsyncClient(timeout=VISION_TIMEOUT) as client:
        r = await client.post(
            f"{ZEN_BASE_URL}/chat/completions",
            headers=headers,
            json=body,
        )
    log.debug("[vision/zen] <- status=%s len=%d", r.status_code, len(r.text))
    if r.status_code >= 400:
        raise VisionError(f"Zen vision error {r.status_code}: {_truncate(r.text)}")
    data = r.json()
    text = data["choices"][0]["message"]["content"]
    if isinstance(text, list):
        text = " ".join(p.get("text", "") for p in text if isinstance(p, dict))
    return text.strip(), ZEN_VISION_MODEL


async def _gemini_vision(image_b64: str, prompt: str) -> tuple[str, str]:
    if not GEMINI_API_KEY:
        raise VisionError("GEMINI_API_KEY missing")
    url = f"{GEMINI_BASE_URL}/models/{GEMINI_MODEL}:generateContent"
    body = {
        "contents": [
            {
                "parts": [
                    {"text": prompt},
                    {
                        "inline_data": {
                            "mime_type": "image/jpeg",
                            "data": image_b64,
                        }
                    },
                ]
            }
        ],
        "generationConfig": {"maxOutputTokens": 200, "temperature": 0.4},
    }
    log.debug("[vision/gemini] -> model=%s", GEMINI_MODEL)
    async with httpx.AsyncClient(timeout=VISION_TIMEOUT) as client:
        r = await client.post(
            url,
            params={"key": GEMINI_API_KEY},
            headers={"Content-Type": "application/json"},
            json=body,
        )
    log.debug("[vision/gemini] <- status=%s len=%d", r.status_code, len(r.text))
    if r.status_code >= 400:
        raise VisionError(f"Gemini error {r.status_code}: {_truncate(r.text)}")
    data = r.json()
    try:
        text = data["candidates"][0]["content"]["parts"][0]["text"]
    except (KeyError, IndexError) as e:
        raise VisionError(f"Unexpected Gemini response: {_truncate(r.text)}") from e
    return text.strip(), GEMINI_MODEL


async def _ollama_vision(image_b64: str, prompt: str) -> tuple[str, str]:
    """Local Ollama on this laptop.

    Setup:
        curl -fsSL https://ollama.com/install.sh | sh
        ollama pull moondream          # ~1.7GB — tiny + fast (recommended)
        # or for higher accuracy:
        ollama pull qwen2.5vl:3b       # ~3GB, better object detail
        ollama pull llava:7b           # ~4.7GB, balanced
        ollama serve                   # runs at http://localhost:11434
    """
    # Small local models (especially moondream:1.8b) get confused by long
    # multi-paragraph prompts. Use a compact prompt that gets cleaner output.
    is_moondream = OLLAMA_MODEL.startswith("moondream")
    if is_moondream:
        local_prompt = (
            "Describe the person in this image in one short sentence. "
            "Mention posture, facial expression, and apparent comfort. "
            "Do not diagnose."
        )
    else:
        # Qwen2.5-VL / LLaVA / MiniCPM follow a richer brief well.
        local_prompt = (
            "You are XSIGHT's vision module. In ONE short sentence, "
            "describe what you see: the person's posture, breathing effort, "
            "facial expression, and any visible objects. Do not diagnose."
        )

    options: dict[str, object] = {
        "temperature": 0.2,
        "num_predict": OLLAMA_NUM_PREDICT,
        "num_ctx": OLLAMA_NUM_CTX,
        "top_p": 0.9,
        "stop": ["\n\n", "Question:", "Q:"],
    }
    if OLLAMA_NUM_GPU > 0:
        options["num_gpu"] = OLLAMA_NUM_GPU
    if OLLAMA_NUM_THREAD > 0:
        options["num_thread"] = OLLAMA_NUM_THREAD

    body = {
        "model": OLLAMA_MODEL,
        "prompt": local_prompt,
        "images": [image_b64],
        "stream": False,
        "keep_alive": OLLAMA_KEEP_ALIVE,
        "options": options,
    }
    log.info(
        "[vision/ollama] -> %s model=%s prompt=%r",
        OLLAMA_BASE_URL,
        OLLAMA_MODEL,
        _truncate(local_prompt, 80),
    )
    try:
        async with httpx.AsyncClient(timeout=VISION_TIMEOUT) as client:
            r = await client.post(f"{OLLAMA_BASE_URL}/api/generate", json=body)
    except httpx.HTTPError as e:
        raise VisionError(
            f"Ollama unreachable at {OLLAMA_BASE_URL}. "
            f"Is `ollama serve` running? Did you `ollama pull {OLLAMA_MODEL}`? ({e})"
        ) from e
    log.debug("[vision/ollama] <- status=%s len=%d", r.status_code, len(r.text))
    if r.status_code == 404:
        raise VisionError(
            f"Ollama 404. Model `{OLLAMA_MODEL}` not found. "
            f"Run: ollama pull {OLLAMA_MODEL}"
        )
    if r.status_code >= 400:
        raise VisionError(f"Ollama error {r.status_code}: {_truncate(r.text)}")
    try:
        data = r.json()
    except ValueError as e:
        raise VisionError(f"Invalid JSON from Ollama: {_truncate(r.text)}") from e
    text = (data.get("response") or "").strip()
    if not text:
        raise VisionError(f"Empty Ollama response: {_truncate(r.text, 600)}")
    if not _looks_like_real_description(text):
        log.warning(
            "[vision/ollama] dropping low-quality output: %r",
            _truncate(text, 80),
        )
        raise VisionError(
            f"Local model returned low-quality output ({_truncate(text, 60)!r}). "
            f"Try a stronger model: `ollama pull qwen2.5vl:3b` and set "
            f"OLLAMA_VISION_MODEL=qwen2.5vl:3b in .env."
        )
    return text, f"ollama/{OLLAMA_MODEL}"


def _looks_like_real_description(text: str) -> bool:
    """Reject obvious junk like '!!!M!!' / 'urny' / 'ids.' from tiny models."""
    t = text.strip()
    if len(t) < 20:
        return False
    words = [w for w in re.split(r"\s+", t) if w]
    if len(words) < 4:
        return False
    # Mostly punctuation / no vowels = junk.
    alpha = sum(c.isalpha() for c in t)
    if alpha < len(t) * 0.5:
        return False
    voweled = sum(1 for w in words if re.search(r"[aeiouAEIOU]", w))
    if voweled < len(words) * 0.6:
        return False
    return True


def b64_from_bytes(raw: bytes) -> str:
    """Convenience helper for callers that have raw image bytes."""
    return base64.b64encode(raw).decode("ascii")


async def ollama_warmup() -> dict[str, object]:
    """Preload the Ollama vision model so the first request is fast.

    Steps:
      1. GET /api/tags  → confirm Ollama is reachable + model is pulled
      2. POST /api/generate with empty prompt + keep_alive → load weights into RAM/VRAM

    Returns a status dict (used by /health/warmup logs). Never raises.
    """
    info: dict[str, object] = {
        "base_url": OLLAMA_BASE_URL,
        "model": OLLAMA_MODEL,
        "reachable": False,
        "model_pulled": False,
        "warmed": False,
        "took_ms": 0,
        "error": None,
    }
    start = time.perf_counter()
    try:
        async with httpx.AsyncClient(timeout=15) as client:
            tags = await client.get(f"{OLLAMA_BASE_URL}/api/tags")
            info["reachable"] = tags.status_code == 200
            if tags.status_code != 200:
                info["error"] = f"/api/tags returned {tags.status_code}"
                return info
            try:
                names = [
                    (m.get("name") or "")
                    for m in (tags.json().get("models") or [])
                ]
            except Exception:
                names = []
            info["model_pulled"] = any(
                n == OLLAMA_MODEL or n.startswith(OLLAMA_MODEL + ":")
                for n in names
            )
            if not info["model_pulled"]:
                info["error"] = (
                    f"model `{OLLAMA_MODEL}` not pulled. "
                    f"Run: ollama pull {OLLAMA_MODEL}"
                )
                return info

            # Tiny generate call with empty prompt loads weights into memory.
            log.info(
                "[vision/ollama] warming up %s (keep_alive=%s)...",
                OLLAMA_MODEL,
                OLLAMA_KEEP_ALIVE,
            )
            warm = await client.post(
                f"{OLLAMA_BASE_URL}/api/generate",
                json={
                    "model": OLLAMA_MODEL,
                    "prompt": "",
                    "stream": False,
                    "keep_alive": OLLAMA_KEEP_ALIVE,
                },
                timeout=120,
            )
            info["warmed"] = warm.status_code == 200
            if warm.status_code != 200:
                info["error"] = f"warmup returned {warm.status_code}: {warm.text[:200]}"
    except httpx.HTTPError as e:
        info["error"] = f"Ollama unreachable: {e}"
    finally:
        info["took_ms"] = int((time.perf_counter() - start) * 1000)
    return info
