# llm-rig

[Русская версия](README.ru.md)

Run a large local LLM (Qwen3.8-27B uncensored) with 256k context on a rented
RTX 5090 (32 GB), RAM-only, plus a tiny zero-dependency search proxy with an
on/off toggle and per-provider credit tracking (Tavily / Exa).

Everything binds to 127.0.0.1. Nothing is exposed to the internet. You reach the
box over an SSH tunnel.

## Prebuilt clore image - paste and go

Built in GitHub Actions on every push to main, published to GHCR. Contains llama.cpp (CUDA
12.8, sm_120), the search proxy, and an entrypoint that downloads the model and starts the
server.

1. In clore choose **Custom Docker image** and paste
```
ghcr.io/promotezor/llm-rig:latest
```
2. Environment variables: add `LLM_API_KEY` (otherwise a random one is generated and printed
   in the logs). Optional: `TAVILY_API_KEY`, `EXA_API_KEY`, `CTX`.
3. Port forwarding: add **8080 TCP** (chat) and optionally **8000 TCP** (search panel).
4. Deploy. The first ~15 minutes are the model download in the logs, then `server is listening`.

Open the address clore gives in My Orders, e.g. `http://n1.de.clorecloud.net:<port>/`.

One-time: the GHCR package is private by default. Make it public (GitHub, profile, Packages,
llm-rig, Package settings, Change visibility, Public), otherwise clore cannot pull it.

## Part 1 - first run on a fresh server (once)

A freshly rented box with nothing installed. Run these on the server itself.

1. SSH in. The address and SSH access come from clore when you rent the box
```
ssh root@<server-ip>
```

2. Clone the repo. It is public, no keys needed
```
git clone https://github.com/promotezor/llm-rig.git
cd llm-rig
```

3. Create the config and fill in 4 keys
```
cp .env.example .env
nano .env
```
Four values in `.env`:

- `TAVILY_API_KEY` and `EXA_API_KEY` - keys from those two services, from their dashboards
- `LLM_API_KEY` and `PROXY_API_KEY` - passwords you invent yourself. Generate two with
  `openssl rand -hex 16` and paste them. Share them with whoever uses the rig.

4. Run the setup
```
./scripts/setup.sh
```
Installs docker + nvidia-toolkit if missing, mounts tmpfs, downloads the model, builds and
starts the containers. Slow the first time (~10-15 min) because llama.cpp compiles for the GPU.

Done. The model is running and waiting for connections. Part 1 is repeated only when you rent
a new box.

## Part 2 - connect when it is already running (every time)

You and your friends do this. One command, then everything is in the browser.

1. Open a tunnel from your laptop (keep this window open while you use it)
```
ssh -L 8080:127.0.0.1:8080 -L 8000:127.0.0.1:8000 root@<server-ip>
```
The services are closed off from the internet; this command forwards their ports to your
laptop, so `localhost:8080` and `localhost:8000` work as if you were on the server.

2. Open the control panel in a browser
```
http://127.0.0.1:8000
```
Paste `PROXY_API_KEY` once. You see the Tavily/Exa balances and a button to toggle search.

3. Point your chat client at the model
- address `http://127.0.0.1:8080/v1`
- API key - your `LLM_API_KEY`

## Toggle search on/off during a session

Open `http://127.0.0.1:8000` and press the toggle button. State lives in tmpfs, survives a
proxy restart, resets with the rental. While search is off, `/search` returns 403 and nothing
is sent to Tavily/Exa.

## Search proxy (for direct API use)

- `POST /search` with `{"query": "...", "provider": "tavily|exa"}` - provider is optional,
  defaults to `SEARCH_PROVIDER`
- `GET /usage` - remaining credits for both providers plus the search state
- `POST /toggle` with `{"search": true|false}` - enable or disable search
- switch provider per request with `?provider=exa` or the `provider` body field
- `SEARCH_DAILY_CAP` in `.env` - hard daily query limit, 0 means no limit

## Model

Default model is `ThinkingCap-Qwen3.8-27B-Uncensored-Heretic` (IQ4_XS GGUF), which keeps the
Qwen3.8 thinking mode while the Heretic ablation removes refusals. It thinks by default.

Fits 32 GB with 256k context - ~15 GB weights + ~8.6 GB KV cache (q8_0) + activations. KV cache
uses q8_0 because F16 KV does not fit 256k on 32 GB and BF16 KV is reported unstable on this
family at long context.

Apache-2.0 alternative - switch `MODEL_REPO` in `.env` to
`mlasli/Qwen3.8-27B-Heretic-Uncensored-IQ4_XS-GGUF`. With that one, uncensored behavior requires
thinking OFF (the ThinkingCap default keeps thinking).

For quants without preserved thinking, toggle it per request via
`chat_template_kwargs: {"enable_thinking": true}` or `reasoning_effort` in the OpenAI-compatible API.

License note - ThinkingCap is PolyForm Small Business, not Apache-2.0. Fine for personal use.
The mlasli alternative is Apache-2.0.

## Friends (multi-user)

Each friend needs SSH access to the box to open the Part 2 tunnel. Two options:

- Add the friend's public key to `~/.ssh/authorized_keys` on the box, and they run the same
  `ssh -L ...` command from their laptop. Private, nothing extra is exposed. Recommended.
- Or bind the services to `0.0.0.0` instead of `127.0.0.1` in `docker-compose.yml` and let
  friends hit `http://<server-ip>:8080` directly. Simpler, but the ports become public and
  scannable, protected only by the API keys. Not recommended.

Either way, friends use the same `LLM_API_KEY` / `PROXY_API_KEY` from `.env`.

## Privacy

- model, logs, and proxy state live in tmpfs at `/mnt/ram`, unmounted on teardown, nothing
  persists on disk
- this protects against data left on the host after you stop; it does not protect against a
  live malicious host reading RAM/VRAM

## Security

- every service binds 127.0.0.1 only, no public ports
- access only via SSH tunnel
- both endpoints require an API key, even on localhost
- containers run non-root
- keep SSH key-only auth

## Stopping

Three levels, from light to full:

- `docker compose stop` / `docker compose start` - pause and resume the containers. The model
  stays in tmpfs, restart is fast. You still pay for the box.
- `./scripts/teardown.sh` - stop and remove containers + images, unmount tmpfs, delete `.env`.
  Clean slate, but the box is still rented.
- Stop the rental on clore.ai - this is what actually stops the per-minute billing. The box and
  everything on it is gone.

## Build note

The llama.cpp CUDA build (Blackwell kernels) takes ~10-15 min the first time. To avoid
rebuilding on every rental, push the image once to a registry (GHCR) and point `image:` at it
instead of building.
