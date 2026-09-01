"""Entry point so you can run the XSIGHT backend with `python main.py`.

Loads `.env` from the `server/` folder if present.

Usage:
    cd server
    python -m venv .venv && source .venv/bin/activate
    pip install -r requirements.txt
    cp .env.example .env  # then edit ZEN_API_KEY
    python main.py
"""

from __future__ import annotations

import os
from pathlib import Path

# Load .env BEFORE importing the app so its module-level os.getenv calls
# pick up the values.
try:
    from dotenv import load_dotenv

    env_path = Path(__file__).resolve().parent / ".env"
    if env_path.exists():
        load_dotenv(env_path)
        print(f"[xsight] Loaded env from {env_path}")
    else:
        print(f"[xsight] No .env file at {env_path} (using process env)")
except ImportError:
    print("[xsight] python-dotenv not installed; skipping .env load")

import uvicorn  # noqa: E402

from app.main import app  # noqa: F401, E402  (re-exported for uvicorn)


def _truthy(value: str | None) -> bool:
    return (value or "").lower() in {"1", "true", "yes", "on"}


def main() -> None:
    host = os.getenv("XSIGHT_HOST", "0.0.0.0")
    port = int(os.getenv("XSIGHT_PORT", "8000"))
    reload = _truthy(os.getenv("XSIGHT_RELOAD", "0"))

    print("=" * 60)
    print(" XSIGHT Backend")
    print("=" * 60)
    print(f" Host:    {host}")
    print(f" Port:    {port}")
    print(f" Reload:  {reload}")
    print(
        f" Chat AI: {'configured' if os.getenv('ZEN_API_KEY') else 'mock (set ZEN_API_KEY)'}"
    )
    print(f" Model:   {os.getenv('ZEN_MODEL', 'gemini-3-flash')}")
    print(f" Vision:  {os.getenv('VISION_PROVIDER', 'local')}")
    if os.getenv("VISION_PROVIDER", "local").lower() == "ollama":
        print(
            f"          → ollama at {os.getenv('OLLAMA_BASE_URL', 'http://localhost:11434')} "
            f"({os.getenv('OLLAMA_VISION_MODEL', 'llava:7b')})"
        )
    print(f" Docs:    http://{host}:{port}/docs")
    print("=" * 60)

    uvicorn.run(
        "app.main:app",
        host=host,
        port=port,
        reload=reload,
        log_level="info",
    )


if __name__ == "__main__":
    main()
