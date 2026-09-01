# XSIGHT lung sound model

Trained artifacts don't live in this folder — the runtime loader
(`server/app/lung_classifier.py`) reads weights from `server/app/`
directly:

```
server/app/lung_model.pt   # PyTorch state_dict — drop-in path
```

This folder only holds the **training notebook**:

```
lung_train.ipynb   # Google Colab notebook, trains on ICBHI 2017
```

Train via `lung_train.ipynb` (Google Colab). Full instructions in
`/LUNG_TRAINING.md` at the repo root.

The backend auto-loads `lung_model.pt` at startup if present. If missing,
it falls back to a spectral-heuristic classifier and the demo still works
(with much lower accuracy — see `LUNG_TRAINING.md`).
