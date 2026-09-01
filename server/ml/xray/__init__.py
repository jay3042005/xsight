"""Optional local chest X-ray classifier loader.

Supports two backends (auto-selected by which weight file exists):
  1. ONNX  — prefers xray.onnx  (fast, no torch at runtime)
  2. Torch — falls back to xray.pt (requires torch + timm)

On-disk layout produced by `xray_train.ipynb`:
    server/ml/xray/
      xray.onnx + xray.onnx.data   # ONNX export (preferred)
      xray.pt                       # PyTorch state_dict (fallback)
      labels.json                   # list[str], len == num_classes
      metrics.json                  # optional training metrics

Architecture is hard-coded to `efficientnet_b0` to match the training
notebook. Override with XRAY_ARCH=<timm-arch> in server `.env`.
"""

from __future__ import annotations

import io
import json
import logging
import os
from pathlib import Path
from typing import Optional

import numpy as np

log = logging.getLogger("xsight.xray")

_MODEL_DIR = Path(__file__).resolve().parent
_ONNX_WEIGHTS = _MODEL_DIR / "xray.onnx"
_PT_WEIGHTS = _MODEL_DIR / "xray.pt"
_LABELS_PATH = _MODEL_DIR / "labels.json"
_METRICS_PATH = _MODEL_DIR / "metrics.json"
_ARCH = os.getenv("XRAY_ARCH", "efficientnet_b0")
_DEVICE = os.getenv("XRAY_DEVICE", "auto")

_backend: Optional[str] = None       # "onnx" | "torch"
_model = None                        # (ort.InferenceSession) or (torch.nn.Module, device)
_labels: list[str] = []
_loaded = False
_load_error: Optional[str] = None
# Temperature-scaling factor (logits / T before softmax) fit on a held-out
# validation split by the training notebook and saved into metrics.json as
# {"temperature": T}. T > 1 softens overconfident softmax outputs, which is
# the common failure mode for small medical-imaging CNNs trained on
# imbalanced data (confidently wrong on the minority class, e.g. TB).
# Defaults to 1.0 (no-op) when metrics.json is absent or has no value —
# fully backward compatible with older model drops.
_temperature: float = 1.0

# ImageNet normalization (same as training)
_MEAN = np.array([0.485, 0.456, 0.406], dtype=np.float32)
_STD = np.array([0.229, 0.224, 0.225], dtype=np.float32)


# ── helpers ──────────────────────────────────────────────────────────

class NotXrayError(Exception):
    """Raised when the uploaded image is not a valid chest X-ray."""
    def __init__(self, reason: str, scores: dict | None = None):
        self.reason = reason
        self.scores = scores or {}
        super().__init__(reason)


def _open_image(raw: bytes):
    """Return a PIL Image from JPEG/PNG/DICOM bytes, converted to RGB."""
    from PIL import Image
    try:
        import pydicom
        ds = pydicom.dcmread(io.BytesIO(raw))
        arr = ds.pixel_array
        return Image.fromarray(arr).convert("L").convert("RGB")
    except Exception:
        return Image.open(io.BytesIO(raw)).convert("RGB")


def validate_xray(img) -> tuple[bool, str, dict]:
    """Check if a PIL Image looks like a real chest X-ray.

    Returns (is_valid, reason, scores) where scores contains individual
    heuristic values.

    Heuristics (tuned on real CXR vs random photo datasets):
      1. Grayscale dominance — real X-rays are near-grayscale; color images
         fail immediately.
      2. Intensity range — X-rays use a wide dynamic range (dark lung fields
         + bright bone/mediastinum).
      3. Dark region ratio — X-rays have significant dark regions (lung fields
         + dark background air).
      4. Corner background darkness — non-medical photos/documents typically
         have bright background corners.
    """
    arr = np.array(img.resize((224, 224)), dtype=np.float32)  # (H, W, 3)
    scores: dict = {}
    reasons: list[str] = []

    # ── 1. Grayscale dominance ───────────────────────────────────
    r, g, b = arr[:, :, 0], arr[:, :, 1], arr[:, :, 2]
    channel_mean = np.stack([r, g, b], axis=0).mean(axis=(1, 2))  # (3,)
    channel_std = float(np.std(channel_mean))
    per_pixel_color_diff = float(
        np.mean(np.abs(r - g) + np.abs(g - b) + np.abs(r - b)) / 3.0
    )
    scores["channel_std"] = channel_std
    scores["color_diff"] = per_pixel_color_diff

    # Color photos (selfies, pets, natural scenes) fail immediately
    if channel_std > 12.0 or per_pixel_color_diff > 15.0:
        reasons.append(
            f"Image appears to be a color photograph (color_diff={per_pixel_color_diff:.1f}). "
            f"Chest X-rays must be grayscale radiographs."
        )

    # ── 2. Intensity dynamic range ───────────────────────────────
    gray = np.mean(arr, axis=2)  # (H, W)
    p5, p95 = np.percentile(gray, 5), np.percentile(gray, 95)
    dynamic_range = float(p95 - p5)
    scores["dynamic_range"] = dynamic_range

    if dynamic_range < 35.0:
        reasons.append(
            f"Very low contrast image (dynamic_range={dynamic_range:.0f}). "
            f"X-rays require high contrast."
        )

    # ── 3. Dark region ratio ─────────────────────────────────────
    dark_ratio = float(np.mean(gray < 75))
    scores["dark_ratio"] = dark_ratio

    if dark_ratio < 0.05:
        reasons.append(
            f"Too few dark regions ({dark_ratio:.1%}). "
            f"Chest X-rays have dark lung fields and dark background."
        )

    # ── 4. Corner background check ───────────────────────────────
    tl = np.mean(gray[:20, :20])
    tr = np.mean(gray[:20, -20:])
    bl = np.mean(gray[-20:, :20])
    br = np.mean(gray[-20:, -20:])
    corner_avg = float((tl + tr + bl + br) / 4.0)
    scores["corner_avg"] = corner_avg

    if tl > 160 and tr > 160 and bl > 160 and br > 160:
        reasons.append(
            f"Image background is too bright (corners avg={corner_avg:.0f}). "
            f"X-rays have dark outer margins."
        )

    scores["fail_count"] = len(reasons)
    is_valid = len(reasons) == 0

    if not is_valid:
        combined_reason = " | ".join(reasons)
        return False, combined_reason, scores

    return True, "OK", scores


def _preprocess(img) -> np.ndarray:
    """Resize + normalise to (1, 3, 224, 224) float32 NCHW tensor."""
    img = img.resize((224, 224))
    arr = np.array(img, dtype=np.float32) / 255.0       # (H, W, 3)
    arr = (arr - _MEAN) / _STD
    arr = np.transpose(arr, (2, 0, 1))                  # CHW
    arr = np.expand_dims(arr, axis=0)                    # NCHW
    return arr.astype(np.float32)


_unstable: bool = True


# ── public API ───────────────────────────────────────────────────────
def is_available() -> bool:
    return _loaded and _model is not None


def status() -> dict[str, object]:
    return {
        "available": is_available(),
        "backend": _backend,
        "weights": str(_ONNX_WEIGHTS if _backend == "onnx" else _PT_WEIGHTS),
        "labels": _labels,
        "arch": _ARCH,
        "temperature": _temperature,
        "unstable": _unstable,
        "model_status": "unstable" if _unstable else "stable",
        "error": _load_error,
    }


def _load_temperature() -> float:
    """Read a calibration temperature from metrics.json, if present."""
    return _load_metrics_config()[0]


def _load_metrics_config() -> tuple[float, bool]:
    """Read calibration temperature and unstable status from metrics.json, if present."""
    if not _METRICS_PATH.exists():
        return 1.0, True
    try:
        with _METRICS_PATH.open() as f:
            data = json.load(f)
        t = float(data.get("temperature", 1.0))
        u = bool(data.get("unstable", True))
        return (t if t > 0 else 1.0), u
    except Exception as e:
        log.warning("[xray/local] failed to read metrics.json: %s", e)
        return 1.0, True


def load() -> None:
    """Load the classifier from disk. Safe to call repeatedly; never raises."""
    global _model, _labels, _loaded, _load_error, _backend, _temperature, _unstable
    if _loaded:
        return

    _temperature, _unstable = _load_metrics_config()

    # Load labels first (shared by both backends)
    if not _LABELS_PATH.exists():
        _load_error = f"labels.json not found in {_MODEL_DIR}"
        log.info("[xray/local] %s", _load_error)
        return
    with _LABELS_PATH.open() as f:
        _labels = json.load(f)
    if not isinstance(_labels, list) or not _labels:
        _load_error = "labels.json must be a non-empty list of strings"
        log.warning("[xray/local] %s", _load_error)
        return

    # ── Try ONNX first (preferred — fast, lightweight) ────────────
    if _ONNX_WEIGHTS.exists():
        try:
            import onnxruntime as ort

            providers = ["CPUExecutionProvider"]
            if _DEVICE != "cpu":
                avail = ort.get_available_providers()
                if "CUDAExecutionProvider" in avail:
                    providers = ["CUDAExecutionProvider", "CPUExecutionProvider"]

            sess = ort.InferenceSession(
                str(_ONNX_WEIGHTS), providers=providers
            )
            _model = sess
            _backend = "onnx"
            _loaded = True
            _load_error = None
            log.info(
                "[xray/local] loaded ONNX model (classes=%d, providers=%s)",
                len(_labels),
                providers,
            )
            return
        except Exception as e:
            log.warning("[xray/local] ONNX load failed: %s — trying PyTorch", e)

    # ── Fallback: PyTorch ────────────────────────────────────────
    if _PT_WEIGHTS.exists():
        try:
            import torch
            import timm

            device = "cpu"
            if _DEVICE == "cuda":
                device = "cuda" if torch.cuda.is_available() else "cpu"
            elif _DEVICE == "auto":
                device = "cuda" if torch.cuda.is_available() else "cpu"

            model = timm.create_model(
                _ARCH, pretrained=False, num_classes=len(_labels)
            )
            state = torch.load(_PT_WEIGHTS, map_location=device)
            model.load_state_dict(state, strict=False)
            model.eval().to(device)
            _model = (model, device)
            _backend = "torch"
            _loaded = True
            _load_error = None
            log.info(
                "[xray/local] loaded PyTorch %s on %s (classes=%d)",
                _ARCH,
                device,
                len(_labels),
            )
            return
        except Exception as e:
            _load_error = str(e)
            log.warning("[xray/local] PyTorch load failed: %s", e)
            return

    _load_error = (
        f"No model weights found in {_MODEL_DIR}. "
        f"Expected xray.onnx or xray.pt."
    )
    log.info("[xray/local] %s", _load_error)


def classify(image_bytes: bytes) -> tuple[str, float, list[float]]:
    """Run inference. Returns (label, confidence, raw_probs).

    Accepts JPEG, PNG, or DICOM bytes.
    """
    if not is_available():
        raise RuntimeError("local xray classifier not available")

    img = _open_image(image_bytes)
    is_valid, reason, scores = validate_xray(img)
    if not is_valid:
        raise NotXrayError(reason, scores)

    x = _preprocess(img)

    if _backend == "onnx":
        return _classify_onnx(x)
    return _classify_torch(x)


def classify_with_heatmap(image_bytes: bytes) -> tuple[str, float, list[float], str]:
    """Run inference + generate Grad-CAM heatmap. Returns (label, confidence, probs, heatmap_b64)."""
    if not is_available():
        raise RuntimeError("local xray classifier not available")

    img = _open_image(image_bytes)
    is_valid, reason, scores = validate_xray(img)
    if not is_valid:
        raise NotXrayError(reason, scores)

    x = _preprocess(img)

    if _backend == "onnx":
        label, prob, probs = _classify_onnx(x)
        heatmap_b64 = _gradcam_onnx(x, img)
    else:
        label, prob, probs = _classify_torch(x)
        heatmap_b64 = _gradcam_torch(x, img)

    return label, prob, probs, heatmap_b64


def _apply_medical_colormap(cam: np.ndarray, original_img) -> str:
    """Transform a 2D normalized activation map into a smooth RGBA medical heatmap PNG (base64).

    Zero/low activation regions are 100% transparent. Focal pathology hot spots
    glow in smooth Cyan -> Yellow -> Deep Red.
    """
    from PIL import Image, ImageFilter
    import io as _io
    import base64

    # 1. Normalize CAM to 0..1
    cam = cam.astype(np.float32)
    cam_min, cam_max = float(cam.min()), float(cam.max())
    if cam_max > cam_min:
        cam_norm_raw = (cam - cam_min) / (cam_max - cam_min)
    else:
        cam_norm_raw = np.zeros_like(cam)

    # 2. Resize to 224x224 and apply Gaussian smoothing for natural anatomical contours
    cam_img = Image.fromarray((cam_norm_raw * 255).astype(np.uint8))
    cam_img = cam_img.resize((224, 224), Image.BILINEAR)
    cam_img = cam_img.filter(ImageFilter.GaussianBlur(radius=5))
    cam_norm = np.array(cam_img, dtype=np.float32) / 255.0

    # 3. Thermal Colormap (Transparent -> Cyan -> Yellow -> Deep Red)
    r = np.clip(2 * cam_norm - 0.3, 0, 1)
    g = np.clip(1.8 * cam_norm * (1.2 - cam_norm), 0, 1)
    b = np.clip(1 - 2.5 * cam_norm, 0, 1)

    # Alpha channel: transparent for baseline, ramps up to 0.75 for peak pathology
    a = np.clip(cam_norm * 0.75, 0, 0.75)

    # 4. Mask out dark background air outside thoracic cavity
    orig_gray = np.array(original_img.resize((224, 224)).convert("L"), dtype=np.float32)
    bg_mask = (orig_gray > 20).astype(np.float32)  # 1 for thoracic cavity, 0 for outer air
    a = a * bg_mask

    rgba = np.stack([r * 255, g * 255, b * 255, a * 255], axis=-1).astype(np.uint8)

    # 5. Convert to RGBA PNG image
    out = Image.fromarray(rgba, mode="RGBA")
    buf = _io.BytesIO()
    out.save(buf, format="PNG")
    return base64.b64encode(buf.getvalue()).decode("ascii")


def _gradcam_onnx(x: np.ndarray, original_img) -> str:
    """Generate high-resolution 14x14 sliding-patch occlusion heatmap for ONNX model."""
    try:
        input_name = _model.get_inputs()[0].name  # type: ignore

        # Base forward pass
        logits_base = _model.run(None, {input_name: x})[0]
        if logits_base.ndim == 2:
            logits_base = logits_base[0]
        pred_idx = int(np.argmax(logits_base))
        base_logit = float(logits_base[pred_idx])

        # 14x14 spatial sensitivity grid
        grid_size = 14
        patch_sz = 32
        cam = np.zeros((grid_size, grid_size), dtype=np.float32)

        # Sliding window occlusion analysis using raw logit drop
        for i in range(grid_size):
            si = max(0, int(i * (224 - patch_sz) / (grid_size - 1)))
            ei = min(224, si + patch_sz)
            for j in range(grid_size):
                sj = max(0, int(j * (224 - patch_sz) / (grid_size - 1)))
                ej = min(224, sj + patch_sz)

                occluded = x.copy()
                occluded[0, :, si:ei, sj:ej] = 0.0  # Zero out patch
                occluded_logits = _model.run(None, {input_name: occluded})[0]
                if occluded_logits.ndim == 2:
                    occluded_logits = occluded_logits[0]
                drop = base_logit - float(occluded_logits[pred_idx])
                cam[i, j] = max(0.0, drop)

        return _apply_medical_colormap(cam, original_img)
    except Exception as e:
        log.warning("[xray] ONNX heatmap generation failed: %s", e)
        return ""


def _gradcam_torch(x: np.ndarray, original_img) -> str:
    """Generate Grad-CAM activation heatmap using PyTorch model."""
    try:
        import torch

        model, device = _model  # type: ignore
        tensor = torch.from_numpy(x).to(device)
        tensor.requires_grad_(True)

        activations: list[torch.Tensor] = []
        gradients: list[torch.Tensor] = []

        def forward_hook(module, input, output):
            activations.append(output)

        def backward_hook(module, grad_in, grad_out):
            gradients.append(grad_out[0])

        # Attach hook to final convolutional feature layer if available
        target_layer = None
        for name, module in reversed(list(model.named_modules())):
            if isinstance(module, torch.nn.Conv2d):
                target_layer = module
                break

        if target_layer is not None:
            h1 = target_layer.register_forward_hook(forward_hook)
            h2 = target_layer.register_full_backward_hook(backward_hook)

        # Forward pass
        logits = model(tensor)
        probs = torch.softmax(logits, dim=1)[0]
        pred_idx = torch.argmax(probs).item()
        target_score = logits[0, pred_idx]

        # Backward pass
        model.zero_grad()
        target_score.backward()

        if target_layer is not None:
            h1.remove()
            h2.remove()

        if activations and gradients:
            act = activations[0][0]  # (C, H, W)
            grad = gradients[0][0]   # (C, H, W)

            # Channel weights alpha_k = mean gradient per channel
            weights = grad.mean(dim=(1, 2), keepdim=True)  # (C, 1, 1)
            cam_tensor = torch.sum(weights * act, dim=0)  # (H, W)
            cam = torch.relu(cam_tensor).detach().cpu().numpy()
        else:
            # Fallback: Saliency map
            grad = tensor.grad[0]
            cam = grad.abs().mean(dim=0).cpu().numpy()

        return _apply_medical_colormap(cam, original_img)
    except Exception as e:
        log.warning("[xray] PyTorch Grad-CAM heatmap failed: %s", e)
        return ""


def _classify_onnx(x: np.ndarray) -> tuple[str, float, list[float]]:
    input_name = _model.get_inputs()[0].name         # type: ignore[union-attr]
    logits = _model.run(None, {input_name: x})[0]   # type: ignore[union-attr]
    # Handle both (1, C) and (C,) output shapes
    if logits.ndim == 2:
        logits = logits[0]
    probs = _softmax(logits / _temperature)
    idx = int(np.argmax(probs))
    return _labels[idx], float(probs[idx]), probs.tolist()


def _classify_torch(x: np.ndarray) -> tuple[str, float, list[float]]:
    import torch

    model, device = _model  # type: ignore[assignment]
    tensor = torch.from_numpy(x).to(device)
    with torch.no_grad():
        logits = model(tensor)
        probs = torch.softmax(logits / _temperature, dim=1)[0].cpu().tolist()
    idx = max(range(len(probs)), key=lambda i: probs[i])
    return _labels[idx], float(probs[idx]), probs


def _softmax(x: np.ndarray) -> np.ndarray:
    e = np.exp(x - np.max(x))
    return e / e.sum(axis=-1, keepdims=True)
