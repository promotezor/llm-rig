# llm-rig

[Русская версия](README.ru.md)

Run a large local LLM (Qwen3.8-27B uncensored) with 256k context on a rented
RTX 5090 (32 GB), RAM-only, plus a tiny zero-dependency search proxy that routes
web search to Tavily or Exa with per-provider credit tracking.

Everything binds to 127.0.0.1. Nothing is exposed to the internet. You reach the
box over an SSH tunnel.

## What's inside

- `llama` - llama.cpp `llama-server` compiled for Blackwell (sm_120),
  OpenAI-compatible API on `127.0.0.1:8080/v1`
- `proxy` - zero-dependency Node proxy on `127.0.0.1:8000` for web search
  (Tavily / Exa) with provider switch and usage view
- model + all runtime data live in tmpfs (`/mnt/ram`), wiped on teardown

## Requirements (on the rented box)

- NVIDIA RTX 5090 (32 GB), recent driver
- ~64 GB RAM recommended (model + KV cache live in tmpfs; 32 GB RAM is tight)
- Docker + NVIDIA Container Toolkit (`setup.sh` installs them if missing)

## Quick start

1. Copy the config and fill in the keys
```
cp .env.example .env
```
Four values to set in `.env`:

- `TAVILY_API_KEY`, `EXA_API_KEY` - keys from those two services (free tiers, no card)
- `LLM_API_KEY`, `PROXY_API_KEY` - passwords you invent yourself, they lock the
  LLM and search endpoints. Generate two with `openssl rand -hex 16` and paste
  them here and share with whoever uses the rig.

2. Run the setup
```
./scripts/setup.sh
```
It mounts tmpfs, downloads the model, builds and starts the containers.

3. From your laptop, open an SSH tunnel
```
ssh -L 8080:127.0.0.1:8080 -L 8000:127.0.0.1:8000 root@<server-ip>
```
4. Use the endpoints below.

## SSH tunnel, why

The services listen on 127.0.0.1 only, so nothing is open to the internet. The
tunnel is how you reach them from your laptop through the one port that is open
(SSH, port 22).

`ssh -L 8080:127.0.0.1:8080` means "take whatever hits port 8080 on my laptop
and forward it over SSH to port 8080 on the server's localhost". So
`http://127.0.0.1:8080` on your laptop is really the server's `127.0.0.1:8080`.

The shape is `-L <local-port>:<remote-host>:<remote-port>`; since the services
are bound to the server's localhost, `remote-host` stays `127.0.0.1`.

## Endpoints

- LLM: `http://127.0.0.1:8080/v1` (OpenAI-compatible, header `Authorization: Bearer $LLM_API_KEY`)
- Search: `http://127.0.0.1:8000` (header `Authorization: Bearer $PROXY_API_KEY`)

## Search proxy

- `POST /search` with `{"query": "...", "provider": "tavily|exa"}` - provider is
  optional, defaults to `SEARCH_PROVIDER`
- `GET /usage` returns remaining credits for both providers (Tavily via its
  `/usage` endpoint, Exa via a local spend counter)
- switch provider per request with `?provider=exa` or the `provider` body field

## Model

Default model is `ThinkingCap-Qwen3.8-27B-Uncensored-Heretic` (IQ4_XS GGUF),
which keeps the Qwen3.8 thinking mode while the Heretic ablation removes
refusals. It thinks by default.

Fits 32 GB with 256k context - ~15 GB weights + ~8.6 GB KV cache (q8_0) +
activations. KV cache uses q8_0 because F16 KV does not fit 256k on 32 GB and
BF16 KV is reported unstable on this family at long context.

Apache-2.0 alternative - switch `MODEL_REPO` in `.env` to
`mlasli/Qwen3.8-27B-Heretic-Uncensored-IQ4_XS-GGUF`. With that one, uncensored
behavior requires thinking OFF (the ThinkingCap default keeps thinking).

For quants without preserved thinking, toggle it per request via
`chat_template_kwargs: {"enable_thinking": true}` or `reasoning_effort` in the
OpenAI-compatible API.

License note - ThinkingCap is PolyForm Small Business, not Apache-2.0. Fine for
personal use. The mlasli alternative is Apache-2.0.

## Friends (multi-user)

Each friend needs SSH access to the box to use the tunnel. Two options:

- Add each friend's public key to the box (`~/.ssh/authorized_keys`), they run
  the same `ssh -L ...` command from their laptop. Private, nothing extra is
  exposed. Recommended.
- Or bind the services to `0.0.0.0` instead of `127.0.0.1` in
  `docker-compose.yml` and let friends hit `http://<server-ip>:8080` directly.
  Simpler, but the ports become public and scannable, protected only by the API
  keys. Not recommended.

Either way, friends use the same `LLM_API_KEY` / `PROXY_API_KEY` from `.env`.

## Privacy

- model, logs, and proxy state live in tmpfs at `/mnt/ram`, unmounted on
  teardown, nothing persists on disk
- this protects against data left on the host after you stop; it does not
  protect against a live malicious host reading RAM/VRAM

## Security

- every service binds 127.0.0.1 only, no public ports
- access only via SSH tunnel
- both endpoints require an API key, even on localhost
- containers run non-root
- keep SSH key-only auth

## Stopping

Three levels, from light to full:

- `docker compose stop` / `docker compose start` - pause and resume the
  containers. The model stays in tmpfs, restart is fast. You still pay for the box.
- `./scripts/teardown.sh` - stop and remove containers + images, unmount tmpfs,
  delete `.env`. Clean slate, but the box is still rented.
- Stop the rental on clore.ai - this is what actually stops the per-minute
  billing. The box and everything on it is gone.

## Build note

The llama.cpp CUDA build (Blackwell kernels) takes ~10-15 min the first time.
To avoid rebuilding on every rental, push the image once to a registry (GHCR)
and point `image:` at it instead of building.
