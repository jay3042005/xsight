# XSIGHT chest X-ray model

Drop trained artifacts in this folder:

```
xray.pt        # PyTorch state_dict — required
labels.json    # list of class names — required
xray.onnx      # optional ONNX export
metrics.json   # optional training metrics
```

Train via `xray_train.ipynb` (Google Colab). Full instructions in
`/XRAY_TRAINING.md` at the repo root.

The backend auto-loads `xray.pt` at startup if present. If missing, it
falls back to the multimodal-LLM screening prompt and the demo still works.
