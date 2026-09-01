# XSIGHT Lung Sound Model — Training Handoff (Google Colab)

This document is for the data scientist / student training the lung sound
classifier that ships with XSIGHT. The goal: produce a small 1D-CNN that
takes a respiratory-cycle audio clip and outputs a probability over:

```
normal | crackle | wheeze | both
```

The trained model gets dropped into `server/app/lung_model.pt` and the
backend auto-loads it at startup, replacing the spectral-heuristic
fallback that ships today.

---

## 1. Why 4 classes, not the 5 currently in the codebase

`server/app/lung_classifier.py` currently lists:

```python
_LABELS = ["normal", "wheeze", "crackle", "rhonchi", "diminished"]
```

That 5-class scheme predates any real training data. No public dataset
labels **rhonchi** or **diminished breath sounds** as a separate class —
the standard benchmark for this task, ICBHI 2017, only labels **crackle**,
**wheeze**, **both** (simultaneous), and **normal**. Training on real data
means adopting ICBHI's 4-class scheme.

**This is a breaking label-set change.** Once `lung_model.pt` lands, the
following also need to change together (not optional — leaving them out of
sync will silently mislabel results):

| File | What references the old 5-class scheme | Needed change |
|---|---|---|
| `server/app/lung_classifier.py` | `_LABELS` list (line ~25) | `["normal", "crackle", "wheeze", "both"]` — **order must match `labels.json`** from the training run |
| `server/app/cdss.py` | `LUNG_SOUND_FINDINGS` dict — keyed by `wheeze/crackle/rhonchi/diminished/normal` | Add a `"both"` entry, drop or keep `rhonchi`/`diminished` as dead/unreachable keys (they'll just never match since the classifier can't produce them) |
| `lib/ui/screens/kiosk_lung_sound_screen.dart` | `_findingTile()` calls hardcode `Wheeze / Crackle / Rhonchi / Diminished / Normal` tiles | Update to `Normal / Crackle / Wheeze / Both` |

None of these are done yet — this notebook only produces the model
weights. Flag when you're ready to wire it in and this can be done as a
single coordinated change across all three files.

---

## 2. What you're producing

| Artifact | Format | Drop-in path | Purpose |
|---|---|---|---|
| Trained weights | `.pt` (PyTorch) | `server/app/lung_model.pt` | Used at runtime |
| Label map | `labels.json` | (reference only — hand-copy into `_LABELS`) | Confirms index → label order |
| Eval report | `metrics.json` | (reference only) | Per-class precision/recall/AUC, confusion matrix, patient-aware split sizes |
| Confusion matrix | `confusion.png` | (reference only) | Visual check of per-class errors |

Unlike the X-ray model, `lung_classifier.py` doesn't currently read
`labels.json`/`metrics.json` from disk — `_LABELS` is hardcoded in the
module and there's no temperature-calibration read path. The notebook
still produces both files for reference/documentation; wiring the backend
to read them dynamically (matching the X-ray pattern) is a reasonable
follow-up but not required for the model to work.

---

## 3. Dataset

**ICBHI 2017 Respiratory Sound Database** — the standard benchmark for
this task.

| Property | Value |
|---|---|
| Recordings | 920 `.wav` files |
| Patients | 126 |
| Respiratory cycles | 6,898 (annotated) |
| Total duration | 5.5 hours |
| Classes | crackle (27.0%), normal (52.8%), wheeze (12.8%), both (7.3%) |
| Kaggle mirror | `nimalanparameshwaran/icbhi-2017-challenge-respiratory-sound-database` |
| Official source | https://bhichallenge.med.auth.gr/ |

**Realistic accuracy expectation — read this before training:** published
ICBHI results in the wild range from 49% to 99%+ accuracy, and that huge
spread is almost entirely explained by evaluation methodology, not model
quality:

| Evaluation method | Typical accuracy | Validity |
|---|---|---|
| Random cycle split (data leakage) | 85-99% | Invalid — same patient in train + test |
| K-fold CV without patient grouping | 80-95% | Invalid — same patient across folds |
| Official ICBHI 60/40 split | 55-72% | Valid — patient-aware |
| Patient-aware custom split | 50-65% | Valid — patient-aware, often stricter |

`lung_train.ipynb` uses `GroupShuffleSplit` on patient ID (§7 in the
notebook) specifically to avoid the leakage that produces the inflated
85-99% numbers. **If your run reports accuracy above ~80%, treat that as a
bug in the split, not a good result** — check that no patient ID appears
in more than one of train/val/test.

State of the art with proper patient-aware evaluation is around 65% ICBHI
Score using a 90M-parameter transformer (BEATs) pretrained on AudioSet.
This notebook uses a much smaller 1D-CNN (~200K params) to match what
`lung_classifier.py` already expects at inference time, so expect numbers
on the lower end of that 50-65% range, not competitive with
transformer-based approaches.

---

## 4. Model recipe

- Architecture: `LungNet` — a small 1D-CNN, **already defined** in
  `server/app/lung_classifier.py::load()`. The notebook copies it
  verbatim so the exported `state_dict` loads with the existing
  `model.load_state_dict(state, strict=False)` call without any
  architecture drift.
- Input: raw 16kHz waveform, 4-second window (64,000 samples),
  peak-normalized — matches `_classify_torch()`'s preprocessing in
  `lung_classifier.py` exactly, so training-time and inference-time
  preprocessing are identical.
- Augmentation: random gain (±15%) + additive Gaussian noise. No
  time-shift/pitch augmentation — revisit if validation accuracy plateaus
  early.
- Class imbalance handling: `WeightedRandomSampler` oversampling on the
  train loader (same pattern as `xray_train.ipynb`).
- Optimizer: AdamW, lr 1e-3, weight decay 1e-4, cosine annealing over 25
  epochs, batch size 32.
- Post-hoc temperature calibration (same Guo et al. 2017 approach as the
  X-ray notebook) — computed and saved to `metrics.json`, but **not
  currently read by `lung_classifier.py` at inference time** (only the
  X-ray path applies a temperature). Wiring that up is a follow-up, not a
  blocker.

---

## 5. Colab quickstart

```python
# 1. Open server/ml/lung/lung_train.ipynb in Google Colab
#    (File > Upload notebook, or push this repo and open from Drive/GitHub)

# 2. Runtime > Change runtime type > T4 GPU

# 3. Run all cells top to bottom. You'll need a Kaggle account for §2
#    (same credential flow as xray_train.ipynb — paste a token in the
#    cell provided, or rely on Drive/local kaggle.json).

# 4. After §12 (Export), download from Colab or copy from Drive:
#    /content/drive/MyDrive/lung_sound/lung_model.pt
#    /content/drive/MyDrive/lung_sound/labels.json
#    /content/drive/MyDrive/lung_sound/metrics.json
#    /content/drive/MyDrive/lung_sound/confusion.png
```

---

## 6. Drop-in workflow

Once you have `lung_model.pt`:

```bash
# On the dev machine running the XSIGHT backend:
cp lung_model.pt server/app/lung_model.pt
```

Then apply the label-set migration described in §1 (this is required —
the model will load but predictions will be mislabeled without it):

1. `server/app/lung_classifier.py` — update `_LABELS` to match
   `labels.json`'s order exactly (should be
   `["normal", "crackle", "wheeze", "both"]`).
2. `server/app/cdss.py` — update `LUNG_SOUND_FINDINGS` to the new label
   set (add `"both"`, decide whether to drop `rhonchi`/`diminished` or
   leave them as unreachable dead entries).
3. `lib/ui/screens/kiosk_lung_sound_screen.dart` — update the "Sound
   Findings" tile list to `Normal / Crackle / Wheeze / Both`.

Restart the backend:

```bash
cd server
python main.py
```

Startup log should confirm:

```
[lung] loaded PyTorch classifier
```

If the file is missing, the backend falls back to the spectral-heuristic
classifier (`_heuristic_classify()` in `lung_classifier.py`) and the demo
still works, just with much lower and less trustworthy accuracy — this is
a rough approximation based on hand-picked frequency thresholds, not a
trained model.

---

## 7. Notebook outline (`lung_train.ipynb`)

The notebook has twelve sections:

1. **Setup** — install deps (torch, torchaudio, kagglehub), mount Drive, configure device.
2. **Download ICBHI** — pulls the Kaggle mirror (`nimalanparameshwaran/icbhi-2017-challenge-respiratory-sound-database`) via `kagglehub`. Uses `MyDrive/lung_sound/kaggle.json`.
3. **Parse annotations** — reads each recording's `.txt` cycle annotations into a `[wav_path, start, end, label, patient_id]` manifest. Patient ID is parsed from the filename (e.g. `101_1b1_Al_sc_Meditron.wav` → `101`).
4. **Audio loading** — `wav_to_pcm16()` is copied verbatim from `lung_classifier.py::_wav_to_pcm16` so training and inference decode WAV bytes identically.
5. **Preview** — plots one waveform per class to sanity-check parsing.
6. **Dataset + windowing** — `LungCycleDS` pads/truncates each cycle to the fixed 4s/64000-sample window, peak-normalizes, and applies light augmentation on the train split only.
7. **Patient-aware split** — `GroupShuffleSplit` on patient ID, 65/15/20 train/val/test, with an explicit assertion that no patient ID appears in more than one split. **The most important cell in the notebook** — see §3 above.
8. **Model** — `LungNet`, copied verbatim from `lung_classifier.py`.
9. **Train loop** — `WeightedRandomSampler` oversampling, AdamW + cosine annealing, saves the best-val-accuracy checkpoint each epoch.
10. **Temperature calibration** — fits scalar `T` on validation logits via LBFGS.
11. **Evaluate** — per-class precision/recall/F1/AUROC, confusion matrix (saved as `confusion.png`), with an explicit warning printed if test accuracy exceeds 85% (likely split leakage).
12. **Export** — `state_dict` + `labels.json` + `metrics.json`.

---

## 8. Ethics + clinical notes

- This model is a screening aid, not a diagnostic tool — same posture as
  the X-ray classifier.
- ICBHI recordings span multiple recording devices (AKG mic, two Littmann
  stethoscope models, Meditron) and 7 chest locations — document which
  device/location distribution your deployment audio resembles, since
  device mismatch is a known source of degraded real-world performance
  for models trained on this dataset.
- Never train on PHI without IRB approval.
- The backend already shows a disclaimer banner in the app; keep it
  regardless of how this model performs.

---

## 9. What to send back

When you're done, hand back:

```
xsight-lung-model-vYYYYMMDD/
├── lung_model.pt      # required
├── labels.json        # required — confirms class order
├── metrics.json       # optional but recommended
├── confusion.png       # optional but recommended
└── README.md          # short notes: val/test accuracy, patient counts, any caveats
```
