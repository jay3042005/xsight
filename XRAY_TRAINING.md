# XSIGHT Chest X-Ray Model — Training Handoff (Google Colab)

This document is for the data scientist / student training the chest X-ray
classifier that ships with XSIGHT. The goal: produce a small CNN that
takes a frontal chest radiograph and outputs a probability over the same
labels the backend expects from `/xray`:

```
normal | pneumonia | tuberculosis | effusion | cardiomegaly | mass | other
```

The trained model gets dropped into `server/ml/xray/` as a `.pt` or `.onnx`
file and the backend auto-loads it at startup, replacing the LLM-based
fallback that ships today.

---

## 1. What you're producing

| Artifact | Format | Drop-in path | Purpose |
|---|---|---|---|
| Trained weights | `.pt` (PyTorch) | `server/ml/xray/xray.pt` | Used at runtime |
| Optional ONNX export | `.onnx` | `server/ml/xray/xray.onnx` | CPU/edge inference |
| Label map | `labels.json` | `server/ml/xray/labels.json` | Maps logit index → label string |
| Eval report | `metrics.json` | `server/ml/xray/metrics.json` | Per-class precision/recall/AUC, confusion matrix, and a fitted `temperature` value (see §7) — **the backend reads `temperature` from this file at load time**, so it must be present for calibration to take effect |
| Confusion matrix | `confusion.png` | `server/ml/xray/confusion.png` | Visual check of per-class errors, esp. `tuberculosis` row/column |

The labels.json must be:

```json
[
  "normal",
  "pneumonia",
  "tuberculosis",
  "effusion",
  "cardiomegaly",
  "mass",
  "other"
]
```

The order matters — the backend uses the index of `argmax` to look up the
label string.

---

## 2. Recommended dataset combo

Public, free, downloadable from Kaggle / HuggingFace:

| Dataset | Size | Labels covered | License |
|---|---|---|---|
| RSNA Pneumonia Detection (Kaggle) | 30k images | pneumonia / normal | CC BY-NC-SA |
| NIH ChestX-ray14 | 112k images | 14 pathologies incl. effusion / cardiomegaly / mass | Open access |
| Shenzhen + Montgomery TB (HuggingFace) | ~720 | tuberculosis / normal | Research |
| Kaggle TB Chest X-ray Database (`tawsifurrahman/tuberculosis-tb-chest-xray-dataset`) | ~700 TB + ~3,500 normal | tuberculosis / normal | Research (see Kaggle page for citation terms) |
| TBX11K Simplified (`vbookshelf/tbx11k-simplified`) | ~800 labeled TB + thousands of non-TB "sick" images | tuberculosis / other (sick-but-not-TB) | Research, CVPR 2020 |
| CheXpert (Stanford) | 224k | 14 pathologies | Research |

**This matters more than it sounds:** the model currently shipping in
`server/ml/xray/` was trained on Shenzhen + Montgomery only — under 720 TB
images total, most from two specific hospital sources. That is why it can
report >99% confidence "normal" on a real TB radiograph: the model never
saw enough TB variety to learn the actual visual signature, so it falls
back to whatever features correlate with the (much larger) normal/pneumonia
classes.

`xray_train.ipynb` now pulls TB images from **four** sources instead of two
(Shenzhen, Montgomery, the Kaggle TB Chest X-ray Database, and TBX11K
Simplified), bringing total TB coverage to roughly 2,000+ images. TB is
still the minority class relative to ~130k RSNA+NIH normal/pneumonia
images, which is why the train loop also uses `WeightedRandomSampler`
oversampling (§3) instead of relying on loss weighting alone.

**Important:** Without TB-specific data, the model will never predict
`tuberculosis` — it can only output classes seen during training. And with
too little TB data, it will predict `tuberculosis` rarely and with
unreliable confidence, which is the failure mode we're fixing here.

---

## 3. Model recipe

- Backbone: `efficientnet_b0` pretrained on ImageNet
- Classifier head: replace final FC with `Linear(in_features, 7)`
- Input: 224×224 grayscale → 3 channels (replicate)
- Augmentations: `RandomHorizontalFlip`, `RandomRotation(±10°)`, `ColorJitter`
- Class imbalance handling: `WeightedRandomSampler` **oversampling** on the
  train loader (not just loss weighting) — this changes how often the model
  actually sees a minority-class example per epoch, not just how hard the
  loss penalizes getting it wrong
- Optimiser: AdamW, lr 3e-4, weight decay 1e-4
- Schedule: cosine annealing over 15 epochs
- Batch size: 32 (fits T4 GPU memory)
- **Post-hoc temperature calibration** fit on the validation split after
  training (§6, step 11) — corrects softmax overconfidence without
  retraining or changing accuracy. The fitted `temperature` is written to
  `metrics.json` and read by the backend at model-load time
  (`server/ml/xray/__init__.py`); older model drops without this field
  default to `temperature=1.0` (no-op), so this is backward compatible.

Expected metrics on a balanced eval split:

| Metric | Target |
|---|---|
| Top-1 accuracy | > 0.78 |
| AUROC (macro) | > 0.85 |
| Pneumonia F1 | > 0.80 |
| TB F1 | > 0.75 |

These are achievable on a Colab T4 in a few hours with the recipe in
`xray_train.ipynb` (longer than the original ~90 min estimate since NIH now
defaults to the full ~112k set and TB now pulls from four sources instead
of two — see §2).

---

## 4. Colab quickstart

```python
# 1. Mount Drive
from google.colab import drive
drive.mount('/content/drive')

# 2. Clone the XSIGHT repo for the helper code (or just copy this notebook)
!git clone https://github.com/yourname/xsight.git /content/xsight
%cd /content/xsight/server/ml/xray

# 3. Install deps
!pip install -q timm torchmetrics scikit-learn kagglehub

# 4. Download datasets to /content/data (use Kaggle CLI or a mirrored zip)
# 5. Run the training cells (see xray_train.ipynb)

# 6. Export
import torch
torch.save(model.state_dict(), '/content/drive/MyDrive/xsight/xray.pt')

# 7. Optional: ONNX export
dummy = torch.randn(1, 3, 224, 224).to(device)
torch.onnx.export(
    model, dummy,
    '/content/drive/MyDrive/xsight/xray.onnx',
    input_names=['image'], output_names=['logits'],
    dynamic_axes={'image': {0: 'batch'}},
    opset_version=17,
)
```

---

## 5. Drop-in workflow

Once you have `xray.pt` (or `xray.onnx`) and `labels.json`:

```bash
# On the dev machine running the XSIGHT backend:
cp xray.pt    server/ml/xray/xray.pt
cp labels.json server/ml/xray/labels.json
cp metrics.json server/ml/xray/metrics.json   # optional but nice for /health
```

Restart the backend:

```bash
cd server
python main.py
```

The startup log will say:

```
[xray] loaded local classifier: server/ml/xray/xray.pt
[xray] labels = ['normal', 'pneumonia', ...]
```

If the file is missing, the backend falls back to the multimodal-LLM
prompt in `server/app/main.py:/xray` so the demo still works.

---

## 6. Notebook outline (`xray_train.ipynb`)

The notebook in this folder has thirteen sections:

1. **Setup** — install deps (timm, kagglehub, pydicom, etc.), mount Drive, configure device.
2. **Download RSNA** — uses `kaggle` to pull RSNA Pneumonia Detection (~1.2 GB DICOM images + labels CSV). Also authenticates Kaggle credentials, reused by step 4.
3. **Download NIH** — uses HuggingFace `snapshot_download` for NIH ChestX-ray14. Defaults to the **full ~112k set** (`NIH_LIMIT = None`); set an int for a fast prototyping run.
4. **Download TB** — pulls from **four** sources: Shenzhen + Montgomery (HuggingFace, ~720 combined) plus the Kaggle TB Chest X-ray Database (~700 TB + ~3,500 normal) and TBX11K Simplified (~800 TB + thousands of non-TB "sick" images mapped to `other`). The two Kaggle downloads are wrapped in try/except so a missing/renamed dataset doesn't hard-fail the whole run — check the printed per-source counts before trusting a training run.
5. **Build manifest** — maps RSNA, NIH, and all four TB sources into our 7-class schema. Creates `[path, label, source]` DataFrame; prints TB-by-source breakdown.
6. **Preview X-rays** — renders 6 sample DICOM/JPEG images (one per class) to visually confirm data.
7. **Split** — patient-stratified 80/10/10 train/val/test.
8. **Transforms** — torchvision pipelines for train + eval. `XrayDS` handles both DICOM and regular images transparently.
9. **Model** — `timm.create_model('efficientnet_b0', pretrained=True, num_classes=7)`.
10. **Train loop** — `WeightedRandomSampler` oversampling on the train loader, AMP (mixed precision), gradient clipping, early stop on val accuracy.
11. **Temperature calibration** — fits a scalar `T` on validation logits via NLL minimization (LBFGS), saved for use at §7's guardrail and by the backend at inference.
12. **Evaluate** — per-class F1, AUROC, confusion matrix (saved as `confusion.png`), explicit TB recall/precision check with a warning if TB recall < 0.75.
13. **Export** — `state_dict` + ONNX + `labels.json` + `metrics.json` (now includes `temperature`, `confusion_matrix`, and per-split sample counts).

---

## 7. Ethics + clinical notes

- These models are screening aids, not diagnostic tools.
- Document the dataset distribution (age, sex, equipment, geography).
- Low-confidence guardrail: the backend (`server/app/main.py`,
  `XRAY_LOW_CONF_THRESHOLD`, default `0.55`) overrides the label to
  `"other"` when `max(softmax) < threshold`, so the frontend shows
  "Inconclusive" instead of a confident-looking wrong answer. This is now
  implemented server-side (previously only documented here, not wired up).
- The temperature calibration in step 11 makes that `0.55` threshold
  meaningful — an uncalibrated model can report 99%+ confidence on a wrong
  prediction, which defeats the guardrail entirely regardless of where the
  threshold is set.
- Never train on PHI without IRB approval.
- The backend already shows a disclaimer banner in the X-Ray screen.

---

## 8. What to send back

When you're done, hand back:

```
xsight-xray-model-vYYYYMMDD/
├── xray.pt              # required
├── xray.onnx            # optional
├── labels.json          # required
├── metrics.json         # optional
├── confusion.png        # optional
└── README.md            # short notes: dataset versions, val AUROC, etc.
```

I'll wire it into the backend's runtime classifier in one commit (already
stubbed at `server/ml/xray/__init__.py`).

---

## 9. Faster paths

If 1.5 hours of Colab training is too long for the demo:

- **Pretrained TorchXrayVision weights** (https://github.com/mlmed/torchxrayvision)
  ship checkpoints trained on multiple chest X-ray datasets. You can wrap
  one of those into our 7-class label space with a small linear adapter
  and skip dataset download entirely.
- **HuggingFace** has several chest X-ray classifiers tagged
  `chest-xray-classification`. Pick one that already outputs labels close
  to ours and remap.

Both paths get you a working `xray.pt` in under 30 minutes.
