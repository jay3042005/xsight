"""Real-time voice pipeline for XSIGHT.

Combines:
  - Voice Activity Detection (webrtcvad) — turn detection
  - Speech-to-Text (faster-whisper) — transcription
  - Text-to-Speech (kokoro-onnx) — streaming audio output

Heavy ML deps are optional and lazy-loaded. If a dep is missing the
loader raises a clear error so the rest of the server keeps running.

Install (one-time):
    pip install -r requirements-voice.txt
    # Download Kokoro model + voices:
    #   https://huggingface.co/hexgrad/Kokoro-82M
    # Save as kokoro-v0_19.onnx + voices.bin in the server/ folder.
"""

from __future__ import annotations

import ctypes
import importlib.util
import json
import logging
import os
import time
from typing import Iterable
from urllib.parse import urlencode
from urllib.request import Request, urlopen

log = logging.getLogger("xsight.voice")


def _bootstrap_cuda_libs() -> None:
    """Add pip-installed nvidia/* lib dirs to LD_LIBRARY_PATH and create version aliases."""
    extra: list[str] = []
    spec = importlib.util.find_spec("nvidia")
    if spec and spec.submodule_search_locations:
        for loc in spec.submodule_search_locations:
            if os.path.isdir(loc):
                for root, dirs, files in os.walk(loc):
                    if os.path.basename(root) == "lib":
                        if root not in extra:
                            extra.append(root)

    if not extra:
        return

    existing = os.environ.get("LD_LIBRARY_PATH", "")
    new = ":".join(extra + ([existing] if existing else []))
    os.environ["LD_LIBRARY_PATH"] = new

    # Eagerly preload and create compatibility symlinks for ctranslate2 (which looks for .so.12)
    for d in extra:
        try:
            cublas13 = os.path.join(d, "libcublas.so.13")
            cublas12 = os.path.join(d, "libcublas.so.12")
            if os.path.exists(cublas13) and not os.path.exists(cublas12):
                try:
                    os.symlink(cublas13, cublas12)
                except OSError:
                    pass

            cublasLt13 = os.path.join(d, "libcublasLt.so.13")
            cublasLt12 = os.path.join(d, "libcublasLt.so.12")
            if os.path.exists(cublasLt13) and not os.path.exists(cublasLt12):
                try:
                    os.symlink(cublasLt13, cublasLt12)
                except OSError:
                    pass

            for fname in os.listdir(d):
                if fname.endswith((".so", ".so.8", ".so.9", ".so.12", ".so.13")) and (
                    fname.startswith("libcublas")
                    or fname.startswith("libcudnn")
                    or fname.startswith("libnvrtc")
                ):
                    try:
                        ctypes.CDLL(os.path.join(d, fname), mode=ctypes.RTLD_GLOBAL)
                    except OSError:
                        pass
        except Exception:
            pass


_bootstrap_cuda_libs()

# --- STT ----------------------------------------------------------------
VOICE_STT_MODEL = os.getenv("VOICE_STT_MODEL", "small")
VOICE_STT_DEVICE = os.getenv("VOICE_STT_DEVICE", "auto")  # cpu | cuda | auto
VOICE_STT_COMPUTE = os.getenv("VOICE_STT_COMPUTE", "int8")
VOICE_STT_LANG = os.getenv("VOICE_STT_LANG", "en")
VOICE_STT_BEAM = int(os.getenv("VOICE_STT_BEAM", "3"))

# --- TTS ----------------------------------------------------------------
# One source of truth. This constant previously defaulted to "kokoro" while
# both consumers re-read the env with a default of "mms", so /health reported
# an engine the server was not using.
VOICE_TTS_PROVIDER = os.getenv("VOICE_TTS_PROVIDER", "mms").lower()
KOKORO_MODEL = os.getenv("KOKORO_MODEL", "kokoro-v0_19.onnx")
KOKORO_VOICES = os.getenv("KOKORO_VOICES", "voices.bin")
KOKORO_VOICE = os.getenv("KOKORO_VOICE", "af_sky")
# MMS-TTS config (Meta Massively Multilingual Speech TTS)
# English: facebook/mms-tts-eng | Tagalog: facebook/mms-tts-tag
MMS_MODEL_ID = os.getenv("MMS_MODEL_ID", "facebook/mms-tts-eng")
# Piper TTS (rhasspy/piper) — the fastest CPU neural option: ~16x realtime
# on a laptop with no GPU, first audio chunk in ~0.1-0.3s. Voices from
# https://huggingface.co/rhasspy/piper-voices (onnx + onnx.json together).
# ryan = male voice. Swapped from lessac (female) on request — same medium
# quality class and 22050 Hz, so the resample path and realtime factor are
# unchanged. Other male options already in the piper-voices repo: john,
# joe, mike, norman, sam, hfc_male.
PIPER_MODEL = os.getenv("PIPER_MODEL", "ml/tts/en_US-ryan-medium.onnx")
DEEPGRAM_API_KEY = os.getenv("DEEPGRAM_API_KEY", "")
DEEPGRAM_TTS_MODEL = os.getenv("DEEPGRAM_TTS_MODEL", "aura-2-thalia-en")
VOICE_TTS_SR = int(os.getenv("VOICE_TTS_SR", "24000"))
# auto = use CUDA when available; cpu = force CPU.
VOICE_TTS_DEVICE = os.getenv("VOICE_TTS_DEVICE", "auto")

# --- VAD ----------------------------------------------------------------
# webrtcvad aggressiveness 0..3 (3 = most aggressive about flagging non-speech)
VOICE_VAD_AGGR = int(os.getenv("VOICE_VAD_AGGR", "2"))

# Trailing silence (ms) that ends a user turn.
VOICE_END_SILENCE_MS = int(os.getenv("VOICE_END_SILENCE_MS", "500"))
# Minimum speech (ms) before we treat a user turn as worth transcribing.
VOICE_MIN_SPEECH_MS = int(os.getenv("VOICE_MIN_SPEECH_MS", "250"))


_stt = None
_tts = None
_vad = None


# ------------------------------------------------------------------------
# Speech-to-Text
# ------------------------------------------------------------------------
def _get_stt():
    global _stt
    if _stt is None:
        try:
            from faster_whisper import WhisperModel
        except ImportError as e:
            raise RuntimeError(
                "faster-whisper not installed. "
                "pip install faster-whisper"
            ) from e

        device = VOICE_STT_DEVICE
        if device == "auto":
            try:
                import ctranslate2  # noqa: WPS433

                cuda_count = ctranslate2.get_cuda_device_count()
                device = "cuda" if cuda_count > 0 else "cpu"
            except Exception:
                device = "cpu"
        compute = (
            VOICE_STT_COMPUTE if device == "cpu" else "float16"
        )
        log.info(
            "[voice/stt] loading faster-whisper '%s' on %s (%s)",
            VOICE_STT_MODEL,
            device,
            compute,
        )
        try:
            _stt = WhisperModel(
                VOICE_STT_MODEL, device=device, compute_type=compute
            )
        except Exception as e:
            if device != "cpu":
                log.warning("[voice/stt] CUDA STT failed (%s), falling back to CPU", e)
                device = "cpu"
                compute = VOICE_STT_COMPUTE
                _stt = WhisperModel(
                    VOICE_STT_MODEL, device=device, compute_type=compute
                )
            else:
                raise
    return _stt


def transcribe_pcm16(pcm_bytes: bytes, sample_rate: int = 16000) -> str:
    """Transcribe a chunk of PCM16 mono audio."""
    if not pcm_bytes:
        return ""
    import numpy as np

    samples = (
        np.frombuffer(pcm_bytes, dtype=np.int16).astype(np.float32) / 32768.0
    )
    if sample_rate != 16000:
        # Lightweight resample — acceptable for STT input.
        ratio = 16000 / sample_rate
        new_len = int(len(samples) * ratio)
        if new_len > 0:
            indices = np.linspace(0, len(samples) - 1, new_len)
            samples = np.interp(indices, np.arange(len(samples)), samples).astype(
                np.float32
            )
    model = _get_stt()
    segments, _ = model.transcribe(
        samples,
        language=VOICE_STT_LANG,
        vad_filter=False,
        beam_size=VOICE_STT_BEAM,
        condition_on_previous_text=False,
        initial_prompt=None,
    )
    return " ".join(s.text.strip() for s in segments).strip()


_mms_cache: dict[str, dict[str, Any]] = {}


def _detect_mms_model(text: str) -> str:
    """Detects whether text is Tagalog or English to pick the correct MMS checkpoint."""
    import re

    text_lower = (text or "").lower()
    tagalog_indicators = {
        "ako", "ikaw", "siya", "kami", "tayo", "kayo", "sila", "magandang", "araw",
        "umaga", "hapon", "gabi", "po", "opo", "ano", "sino", "bakit", "paano",
        "kailan", "saan", "kamusta", "kumusta", "salamat", "walang", "anuman",
        "oo", "hindi", "babae", "lalaki", "bata", "doktor", "pasyente", "sakit",
    }
    words = set(re.findall(r"\b\w+\b", text_lower))
    if words.intersection(tagalog_indicators):
        return "facebook/mms-tts-tgl"
    return "facebook/mms-tts-eng"


def _get_mms_tts(model_id: str | None = None) -> dict[str, Any]:
    model_id = model_id or os.getenv("MMS_MODEL_ID", "facebook/mms-tts-eng")
    if model_id not in _mms_cache:
        try:
            from transformers import VitsModel, AutoTokenizer
            import torch
        except ImportError as e:
            raise RuntimeError(
                "transformers and torch are required for MMS-TTS. "
                "pip install transformers torch scipy"
            ) from e

        log.info("[voice/tts] loading Meta MMS-TTS model=%s", model_id)
        device = "cuda" if (VOICE_TTS_DEVICE in ("auto", "cuda") and torch.cuda.is_available()) else "cpu"
        try:
            model = VitsModel.from_pretrained(model_id).to(device)
            tokenizer = AutoTokenizer.from_pretrained(model_id)
            _mms_cache[model_id] = {
                "provider": "mms",
                "model": model,
                "tokenizer": tokenizer,
                "device": device,
                "model_id": model_id,
            }
        except Exception as e:
            raise RuntimeError(
                f"Failed to load Meta MMS-TTS model '{model_id}': {e}"
            ) from e
    return _mms_cache[model_id]


def _get_tts():
    global _tts
    if _tts is None:
        provider = VOICE_TTS_PROVIDER
        if provider == "deepgram":
            if not DEEPGRAM_API_KEY:
                raise RuntimeError("DEEPGRAM_API_KEY is required for Deepgram TTS")
            _tts = {"provider": "deepgram"}
            return _tts
        if provider == "kokoro" and (not os.path.exists(KOKORO_MODEL) or not os.path.exists(KOKORO_VOICES)):
            log.warning("[voice/tts] Kokoro weights missing, falling back to MMS-TTS")
            provider = "mms"
        if provider == "piper" and not os.path.exists(PIPER_MODEL):
            log.warning(
                "[voice/tts] Piper model missing at %s, falling back to MMS-TTS",
                PIPER_MODEL,
            )
            provider = "mms"

        if provider in ("mms", "mms-tts", "facebook/mms-tts"):
            _tts = _get_mms_tts()
        elif provider == "piper":
            try:
                from piper import PiperVoice
            except ImportError as e:
                raise RuntimeError(
                    "piper-tts not installed. pip install piper-tts"
                ) from e
            log.info("[voice/tts] loading Piper model=%s", PIPER_MODEL)
            _tts = {"provider": "piper", "voice": PiperVoice.load(PIPER_MODEL)}
        elif provider == "kokoro":
            try:
                from kokoro_onnx import Kokoro
            except ImportError as e:
                raise RuntimeError(
                    "kokoro-onnx not installed. "
                    "pip install kokoro-onnx soundfile onnxruntime"
                ) from e
            if not os.path.exists(KOKORO_MODEL):
                raise RuntimeError(
                    f"Kokoro model not found at {KOKORO_MODEL}. "
                    "Download from https://huggingface.co/hexgrad/Kokoro-82M"
                )
            if not os.path.exists(KOKORO_VOICES):
                raise RuntimeError(
                    f"Kokoro voices not found at {KOKORO_VOICES}. "
                    "Download voices.bin from the model card."
                )

            # Pick ONNX Runtime providers based on availability.
            providers: list[str] | None = None
            try:
                import onnxruntime as ort  # noqa: WPS433

                avail = ort.get_available_providers()
                if VOICE_TTS_DEVICE in {"auto", "cuda"}:
                    if "CUDAExecutionProvider" in avail:
                        providers = ["CUDAExecutionProvider", "CPUExecutionProvider"]
                if providers is None:
                    providers = ["CPUExecutionProvider"]
            except Exception:
                pass

            log.info(
                "[voice/tts] loading Kokoro model=%s voices=%s providers=%s",
                KOKORO_MODEL,
                KOKORO_VOICES,
                providers,
            )
            try:
                _tts = Kokoro(KOKORO_MODEL, KOKORO_VOICES, providers=providers)
            except TypeError:
                _tts = Kokoro(KOKORO_MODEL, KOKORO_VOICES)
        else:
            raise RuntimeError(
                f"Unknown VOICE_TTS_PROVIDER={provider}"
            )
    return _tts


def synthesize_pcm16(
    text: str,
    voice: str | None = None,
    target_sr: int = 24000,
) -> Iterable[bytes]:
    """Yield PCM16 mono audio chunks at `target_sr` (~100ms each)."""
    text = (text or "").strip()
    if not text:
        return

    provider = VOICE_TTS_PROVIDER
    chunk_bytes = target_sr * 2 * 100 // 1000  # ~100 ms PCM frame

    if provider in ("mms", "mms-tts", "facebook/mms-tts"):
        import torch

        # Automatically select English vs Tagalog checkpoint based on text content
        target_model_id = _detect_mms_model(text)
        tts_obj = _get_mms_tts(target_model_id)

        model = tts_obj["model"]
        tokenizer = tts_obj["tokenizer"]
        device = tts_obj["device"]
        native_sr = int(getattr(model.config, "sampling_rate", 16000))

        clauses = _split_for_streaming(text)
        log.info("[voice/tts/mms] streaming %d clauses using %s", len(clauses), target_model_id)

        for clause in clauses:
            clause = clause.strip()
            if not clause:
                continue
            try:
                inputs = tokenizer(clause.lower(), return_tensors="pt").to(device)
                with torch.no_grad():
                    output = model(**inputs).waveform
                samples = output.squeeze().cpu().numpy()
            except Exception as e:
                log.warning("[voice/tts/mms] clause failed (%r): %s", clause[:40], e)
                continue

            pcm = _floats_to_pcm16(samples, native_sr, target_sr)
            for i in range(0, len(pcm), chunk_bytes):
                yield pcm[i : i + chunk_bytes]
        return

    if provider == "deepgram":
        if not DEEPGRAM_API_KEY:
            raise RuntimeError("DEEPGRAM_API_KEY is required for Deepgram TTS")
        query = urlencode({"model": DEEPGRAM_TTS_MODEL, "encoding": "linear16", "sample_rate": target_sr})
        request = Request(
            f"https://api.deepgram.com/v1/speak?{query}",
            data=json.dumps({"text": text}).encode(),
            headers={"Authorization": f"Token {DEEPGRAM_API_KEY}", "Content-Type": "application/json"},
            method="POST",
        )
        try:
            with urlopen(request, timeout=30) as response:
                pcm = response.read()
        except Exception as e:
            raise RuntimeError(f"Deepgram TTS request failed: {e}") from e
        for i in range(0, len(pcm), chunk_bytes):
            yield pcm[i : i + chunk_bytes]
        return

    if provider == "piper":
        import numpy as np

        pvoice = _get_tts()["voice"]
        native_sr = int(pvoice.config.sample_rate)  # 22050 for lessac-medium

        for clause in _split_for_streaming(text):
            clause = clause.strip()
            if not clause:
                continue
            try:
                # Piper streams AudioChunks as it synthesizes; concatenate one
                # clause's chunks, then re-chunk at the pipeline's frame size.
                samples = np.concatenate(
                    [
                        np.frombuffer(
                            ch.audio_int16_bytes, dtype=np.int16
                        ).astype(np.float32)
                        / 32768.0
                        for ch in pvoice.synthesize(clause)
                    ]
                )
            except Exception as e:
                log.warning(
                    "[voice/tts/piper] clause failed (%r): %s", clause[:40], e
                )
                continue
            if samples.size == 0:
                continue
            pcm = _floats_to_pcm16(samples, native_sr, target_sr)
            for i in range(0, len(pcm), chunk_bytes):
                yield pcm[i : i + chunk_bytes]
        return

    tts = _get_tts()

    voice = voice or KOKORO_VOICE
    # Break into spoken clauses. First piece is intentionally short.
    clauses = _split_for_streaming(text)
    log.debug("[voice/tts/kokoro] streaming %d clauses", len(clauses))

    for clause in clauses:
        clause = clause.strip()
        if not clause:
            continue
        try:
            samples, native_sr = tts.create(
                clause, voice=voice, lang="en-us"
            )
        except Exception as e:
            log.warning("[voice/tts] clause failed (%r): %s", clause[:40], e)
            continue
        pcm = _floats_to_pcm16(samples, native_sr, target_sr)
        for i in range(0, len(pcm), chunk_bytes):
            yield pcm[i : i + chunk_bytes]


def _split_for_streaming(text: str) -> list[str]:
    """Split text into short clauses for ultra-low-latency real-time streaming TTS."""
    import re

    text = text.strip()
    if not text:
        return []

    # Split into sentences first.
    sentences = re.split(r"(?<=[.!?])\s+", text)
    sentences = [s.strip() for s in sentences if s.strip()]
    if not sentences:
        return [text]

    out: list[str] = []
    for s in sentences:
        words = s.split()
        if len(words) > 6:
            for i in range(0, len(words), 5):
                sub = " ".join(words[i : i + 5]).strip()
                if sub:
                    out.append(sub)
        else:
            out.append(s)
    return out


def _floats_to_pcm16(samples, native_sr: int, target_sr: int) -> bytes:
    import numpy as np

    if not isinstance(samples, np.ndarray):
        samples = np.asarray(samples, dtype=np.float32)
    if native_sr != target_sr:
        ratio = target_sr / native_sr
        new_len = int(len(samples) * ratio)
        if new_len > 0:
            indices = np.linspace(0, len(samples) - 1, new_len)
            samples = np.interp(
                indices, np.arange(len(samples)), samples
            ).astype(np.float32)
    return (np.clip(samples, -1.0, 1.0) * 32767).astype(np.int16).tobytes()


# ------------------------------------------------------------------------
# Voice Activity Detection (webrtcvad with energy-based fallback)
# ------------------------------------------------------------------------
class _EnergyVad:
    """Pure-Python fallback VAD that thresholds short-term RMS energy.

    Used when webrtcvad isn't installed or fails to import. It compares the
    frame's RMS energy against an adaptive noise floor.
    """

    def __init__(self, aggressiveness: int) -> None:
        # Aggressiveness 0..3 → energy threshold multiplier.
        self._mult = [1.6, 2.0, 2.5, 3.0][max(0, min(3, aggressiveness))]
        self._noise_rms = 200.0  # initial noise floor (PCM16 units)

    def is_speech(self, pcm_frame: bytes, sample_rate: int = 16000) -> bool:
        import struct

        if not pcm_frame:
            return False
        n = len(pcm_frame) // 2
        if n == 0:
            return False
        # Sum of squares without numpy — keeps the fallback dependency-free.
        samples = struct.unpack(f"<{n}h", pcm_frame[: n * 2])
        sq_sum = 0
        for s in samples:
            sq_sum += s * s
        rms = (sq_sum / n) ** 0.5
        threshold = self._noise_rms * self._mult
        is_voice = rms > threshold
        # Slow-track the noise floor when frame is silent.
        if not is_voice:
            self._noise_rms = 0.95 * self._noise_rms + 0.05 * rms
            self._noise_rms = max(150.0, self._noise_rms)
        return is_voice


def _get_vad():
    global _vad
    if _vad is None:
        try:
            import webrtcvad

            _vad = webrtcvad.Vad(VOICE_VAD_AGGR)
            log.info(
                "[voice/vad] webrtcvad loaded (aggressiveness=%d)",
                VOICE_VAD_AGGR,
            )
        except Exception as e:
            log.warning(
                "[voice/vad] webrtcvad unavailable (%s) — using energy VAD fallback",
                e,
            )
            _vad = _EnergyVad(VOICE_VAD_AGGR)
    return _vad


def is_speech(pcm_frame: bytes, sample_rate: int = 16000) -> bool:
    """`pcm_frame` must be 10/20/30 ms of 16-bit mono PCM."""
    return _get_vad().is_speech(pcm_frame, sample_rate)


# ------------------------------------------------------------------------
# Health
# ------------------------------------------------------------------------
def voice_status() -> dict[str, object]:
    """Reports which voice providers are loadable. Never raises."""
    info: dict[str, object] = {
        "stt_model": VOICE_STT_MODEL,
        "stt_device": VOICE_STT_DEVICE,
        "tts_provider": VOICE_TTS_PROVIDER,
        "tts_voice": KOKORO_VOICE,
        "tts_sr": VOICE_TTS_SR,
        "tts_device": VOICE_TTS_DEVICE,
        "mms_model_id": MMS_MODEL_ID,
        "deepgram_tts_model": DEEPGRAM_TTS_MODEL if VOICE_TTS_PROVIDER == "deepgram" else None,
        "piper_model": PIPER_MODEL if VOICE_TTS_PROVIDER == "piper" else None,
        "vad_aggressiveness": VOICE_VAD_AGGR,
        "stt_loadable": False,
        "tts_loadable": False,
        "vad_loadable": False,
        "errors": {},
    }
    try:
        _get_stt()
        info["stt_loadable"] = True
    except Exception as e:
        info["errors"]["stt"] = str(e)
    try:
        _get_tts()
        info["tts_loadable"] = True
    except Exception as e:
        info["errors"]["tts"] = str(e)
    try:
        _get_vad()
        info["vad_loadable"] = True
    except Exception as e:
        info["errors"]["vad"] = str(e)
    return info


def voice_warmup() -> None:
    """Pre-load STT + TTS so the first request doesn't pay the cold-start cost."""
    import numpy as np

    try:
        # STT warm: a 0.2s silent buffer.
        stt = _get_stt()
        silent = np.zeros(int(16000 * 0.2), dtype=np.float32)
        list(stt.transcribe(silent, language=VOICE_STT_LANG, beam_size=1)[0])
        log.info("[voice/stt] warmup ok")
    except Exception as e:
        log.warning("[voice/stt] warmup failed: %s", e)

    try:
        # TTS warm: tiny utterance.
        tts = _get_tts()
        if isinstance(tts, dict) and tts.get("provider") == "deepgram":
            next(synthesize_pcm16("ok"))
        elif isinstance(tts, dict) and tts.get("provider") == "piper":
            # Pays the ~2s model load here so the first spoken reply does not.
            next(tts["voice"].synthesize("ok"), None)
        elif isinstance(tts, dict) and tts.get("provider") == "mms":
            import torch
            inputs = tts["tokenizer"]("ok", return_tensors="pt").to(tts["device"])
            with torch.no_grad():
                tts["model"](**inputs)
        else:
            tts.create("ok", voice=KOKORO_VOICE, lang="en-us")
        log.info("[voice/tts] warmup ok")
    except Exception as e:
        log.warning("[voice/tts] warmup failed: %s", e)
