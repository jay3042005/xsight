# XSIGHT Backend (FastAPI)

Python proxy for the XSIGHT mobile app. Hides the OpenCode Zen API key,
exposes chat / vision / lung-sound / vitals endpoints, and streams mock
sensor data over WebSocket.

## Setup

```bash
cd server
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env
# then edit .env and set ZEN_API_KEY
```

## Run

```bash
python main.py
```

`main.py` automatically loads `server/.env`. You can still override any value
with a real env var (env vars win over `.env`).

| Var               | Default                  | Purpose                       |
| ----------------- | ------------------------ | ----------------------------- |
| `ZEN_API_KEY`     | empty                    | OpenCode Zen API key          |
| `ZEN_MODEL`       | `deepseek-v4-flash-free` | Chat model id                 |
| `ZEN_VISION_MODEL`| `gemini-3-flash`         | Vision model id               |
| `ZEN_BASE_URL`    | `https://opencode.ai/zen/v1` | Override only if proxied  |
| `XSIGHT_HOST`     | `0.0.0.0`                | Bind host                     |
| `XSIGHT_PORT`     | `8000`                   | Bind port                     |
| `XSIGHT_RELOAD`   | `0`                      | Set `1` for auto-reload       |

Visit http://localhost:8000/docs for the interactive Swagger UI.

## Endpoints

| Method | Path           | Purpose                                |
| ------ | -------------- | -------------------------------------- |
| GET    | `/health`      | Status + AI configured flag            |
| POST   | `/chat`        | Chat completion (Zen proxy)            |
| POST   | `/vision`      | Vision analysis on a base64 image      |
| POST   | `/lung-sound`  | Multipart `.wav` -> mock classifier    |
| POST   | `/vitals`      | Risk scoring from vitals               |
| WS     | `/ws/vitals`   | Streams mock vitals every second       |

## Connect From Flutter

```bash
flutter run --dart-define=BACKEND_BASE_URL=http://10.0.2.2:8000
```

Notes:
- Android emulator → `10.0.2.2` reaches the host machine
- iOS simulator   → `localhost` works
- Physical device → use your LAN IP (e.g. `http://192.168.1.20:8000`)

## Security

- Never expose this server publicly without auth.
- Keep `ZEN_API_KEY` only in env vars or a secret manager.
- Free Zen models log prompts. Don't send PHI through them.
