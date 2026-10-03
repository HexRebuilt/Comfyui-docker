# MCP Integration

Drive this ComfyUI container from Claude Code, Claude Desktop, Cursor, or any
MCP-speaking agent.

## What to use

There is an official server: **[`Comfy-Org/comfy-mcp`](https://github.com/Comfy-Org/comfy-mcp)** —
the same GitHub organisation that publishes ComfyUI itself. It is published to the
official MCP Registry as `io.github.Comfy-Org/comfy-mcp`.

Prefer it over the community alternatives. Notable ones exist
(`artokun/comfyui-mcp`, `joenorton/comfyui-mcp-server`, `heshengtao/comfyui_LLM_party`),
but the official one is actively maintained, wraps `comfy-cli`, and introspects
your *actual* install — the nodes, models and templates your container really has,
custom nodes included.

Licence is **AGPL-3.0-or-later OR Commercial**. Installing it on your own host to
drive your own ComfyUI is fine. Note that redistributing it inside a published
container image would be a different matter, which is why this project does not
bake it in.

## Verified against this image

Tested both ways — containerised via `docker compose --profile mcp run`, and
installed on the host — against this exact ComfyUI (0.38.0, torch 2.11.0+cu130,
dual GPU):

| Check | Result |
|-------|--------|
| MCP handshake (`initialize`, protocol 2025-06-18) | OK |
| Tool count | 39 |
| `server_info` | OK |
| `system_stats` | OK — sees both GPUs, torch 2.11.0+cu130 |
| `nodes` (`action=search`) | OK — found 6 `KSampler` variants from the live install |
| `search_templates` | OK — 105 templates from the running server |
| `search_models` | OK — returned a well-formed empty result (no models installed) |
| `generate_image` | Reached ComfyUI, which replied `no_checkpoint_available` |

The containerised run was verified end-to-end from the published image:
`docker compose --profile mcp run --rm -T comfy-mcp` completed the handshake,
reported ComfyUI 0.38.0 via `system_stats`, and listed 484 templates.

That `no_checkpoint_available` row is the expected result on a fresh checkout:
the submit path works, there is just no checkpoint yet. Once
`./models/checkpoints` holds a model, generation works.

Two container-only failure modes worth knowing, because neither is visible when
the server runs on your own machine:

- Running as an account whose `HOME` is unwritable (`/nonexistent` for UID 65534)
  makes comfy-cli fail to write `~/.config/comfy-cli`. Every tool call errors
  with `PermissionError` while the MCP handshake still appears to succeed.
  `Dockerfile.mcp` creates a real user and `HOME` for this reason.
- `python:slim` ships no `git`, which comfy-cli shells out to. Without it,
  workspace-backed tools crash rather than degrading.

## Option A: containerised (recommended)

The server ships as its own small image, built from `Dockerfile.mcp`:

```
ghcr.io/hexrebuilt/comfyui-docker-mcp:latest
```

216 MB, `python:3.12-slim`, no CUDA and no GPU. It is deliberately **not** baked
into the 11 GB ComfyUI image: it needs none of that runtime, and it is
AGPL-3.0-or-later while the ComfyUI image is MIT.

It is already in `docker-compose.yml` behind the `mcp` profile, so a plain
`docker compose up` is unaffected:

```bash
docker compose --profile mcp pull        # refresh
docker compose --profile mcp run --rm comfy-mcp
```

To drive it from an MCP client, give the client a `docker compose run` command.
It reaches ComfyUI by service name over the compose network, so no host port is
involved.

### Claude Code

```bash
claude mcp add comfy-mcp -- docker compose --profile mcp run --rm -T comfy-mcp
```

### Claude Desktop

`claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "comfy-mcp": {
      "command": "docker",
      "args": [
        "compose", "--profile", "mcp", "-f",
        "/absolute/path/to/Comfyui-docker/docker-compose.yml",
        "run", "--rm", "-T", "comfy-mcp"
      ]
    }
  }
}
```

Run the command from the repository directory so compose finds the file, or pass
`-f` with an absolute path as above. `-T` keeps stdin attached, which is the
MCP stream; without it the server sees a closed pipe and exits immediately.

## Option C: over the network

`comfy-mcp` is **stdio-only** — upstream hardcodes `mcp.run(transport="stdio")`
and there is no HTTP transport to switch on. To reach it from another machine,
`mcp-http-bridge.py` launches it as a subprocess and re-publishes it as a
Streamable HTTP MCP endpoint using `fastmcp`.

Already wired into compose behind the `mcp-http` profile:

```bash
echo "MCP_AUTH_TOKEN=$(openssl rand -hex 24)" >> .env
docker compose --profile mcp-http up -d comfy-mcp-http
```

That publishes `127.0.0.1:8081` — loopback only, so by default it is reachable
from the host and nothing else. Point a client at it:

```json
{
  "mcpServers": {
    "comfy-mcp": {
      "type": "http",
      "url": "http://127.0.0.1:8081/mcp",
      "headers": { "Authorization": "Bearer YOUR_TOKEN" }
    }
  }
}
```

Verified over the network through compose: 39 tools listed, `system_stats`
reporting ComfyUI 0.38.0 / torch 2.11.0+cu130, 484 templates, and HTTP 401 for a
missing or wrong token versus 200 for the correct one.

### Reaching it from another machine

Set `MCP_BIND_ADDR=0.0.0.0` in `.env` to publish on the LAN. Read this first.

## Security: the network exposure

**This endpoint is a remote shell for your GPU.** comfy-mcp has no
authentication of its own, so the bridge adds it, and it is not optional:

- `MCP_AUTH_TOKEN` is **required**. Without it the bridge refuses to start, and
  it refuses specifically when the bind address is not loopback.
- Tokens shorter than 16 characters are rejected.
- Comparison is constant-time (`hmac.compare_digest`).

What an authenticated caller can do: run GPU workloads, write files into the
container, and call `partner_generate`, which **spends real credits** on hosted
partner models. Treat the token like a password and an SSH key.

Also true of the existing setup, and worth repeating here:

- Port 8188 is an **unauthenticated ComfyUI UI**. This bridge gives network
  clients programmatic access to the same machine, so it is not a smaller
  exposure — it is a different shape of the same one.
- Anyone who can reach this can drive the GPU at your expense and consume disk
  with generated output.

Prefer, in order: bind to `127.0.0.1` and reach it over SSH or a Tailscale/WireGuard
tunnel; or keep it on the LAN behind a reverse proxy that terminates TLS and
adds its own auth; and never expose it to the internet directly.

If you bind beyond loopback, set `MCP_BIND_ADDR` explicitly — the default is
deliberately the conservative one.

### Staying current

Two independent mechanisms, so you get fresh code either way:

- **At startup.** `mcp-entrypoint.sh` compares the installed `comfy-mcp` and
  `comfy-cli` against the latest release on PyPI and upgrades only what is
  behind. A start costs two small HTTP requests, not a dependency resolve.
- **Weekly.** A scheduled CI run rebuilds and re-pushes the image every Monday,
  so `docker compose --profile mcp pull` also refreshes it.

Note *when* the startup update runs: before the MCP handshake, never during a
session. This container is spawned fresh for every session, so each one runs a
known-current version without any risk of swapping code underneath a live
conversation. That is the meaningful difference from the ComfyUI image, which is
a single long-running process and updates in place.

Note the two images tag `latest` differently, on purpose:

| Image | `latest` means |
|-------|----------------|
| `comfyui-docker` | newest **release** (moved by pushing a `v*` tag) |
| `comfyui-docker-mcp` | newest **build** of the default branch, including the weekly refresh |

A release should never silently swap the code an agent is driving mid-session,
whereas the MCP server is disposable and is expected to be current.

## Option B: on the host

Install it directly instead. Use this if you would rather not add a container to
the loop, or if your MCP client already manages Python environments well.

### Install

The server runs on your **host**, as a subprocess your AI client launches. It is
not a container and needs no GPU.

With `uv` (recommended — it needs no `python3-venv` on the host):

```bash
uv tool install "comfy-cli>=1.14.0"   # exposes `comfy` on PATH
uv tool install comfy-mcp              # exposes `comfy-mcp`
export PATH="$HOME/.local/bin:$PATH"
```

Install them as **two separate tools**. `uv tool install comfy-mcp --with
comfy-cli` looks like the tidier option and does install the engine, but only
exposes `comfy-mcp`; `comfy` ends up buried in uv's private environment and never
reaches `PATH`. Since `COMFY_BIN` has to point at a real path, that layout makes
every tool call fail with `"comfy" not found on PATH`.

With plain pip into a venv, which puts both on the same `PATH` naturally:

```bash
python3 -m venv ~/comfy-mcp-venv
~/comfy-mcp-venv/bin/pip install "comfy-mcp" "comfy-cli>=1.14.0"
export PATH="$HOME/comfy-mcp-venv/bin:$PATH"
```

`comfy-cli` is a separate install on purpose — the server runs whichever `comfy`
binary is on `PATH`, and enforces the version floor at runtime rather than
pinning a second copy.

Verify — both must resolve:

```bash
command -v comfy        # the engine, needs >= 1.14.0
comfy --version
comfy-mcp --help        # the server. Do NOT run it bare to test: it is stdio
```

### Point it at the container

ComfyUI must be up first:

```bash
docker compose up -d
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8188/system_stats   # 200
```

`comfy-compose` publishes port 8188 on the host, which is exactly the address the
server defaults to, so usually no configuration is needed. Set
`COMFY_LOCAL_URL` only if you moved the port.

### Client configuration

`COMFY_BIN` is not optional in practice: MCP clients launch the server with their
own environment, which often does not include your shell `PATH`.

#### Claude Code

`--env` must come before the `--` separator:

```bash
claude mcp add comfy-mcp --env COMFY_BIN="$(command -v comfy)" -- comfy-mcp
```

#### Claude Desktop

`claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "comfy-mcp": {
      "command": "comfy-mcp",
      "env": {
        "COMFY_BIN": "/home/you/.local/bin/comfy"
      }
    }
  }
}
```

#### Cursor

`~/.cursor/mcp.json`:

```json
{
  "mcpServers": {
    "comfy-mcp": {
      "command": "comfy-mcp",
      "env": {
        "COMFY_BIN": "/home/you/.local/bin/comfy"
      }
    }
  }
}
```

## What works, and what does not

This is the part worth internalising. `comfy-mcp` was built for a ComfyUI
**installed on the same machine**, and it wraps a CLI that manages a local
workspace. This container is a different shape, so the tool surface splits:

**Fully supported** — these talk to ComfyUI over HTTP, which is all they need:

`generate_image`, `run_workflow`, `run_template`, `job`, `fetch_outputs`,
`server_info`, `system_stats`, `search_models`, `nodes`, `search_templates`,
`get_template`, `fetch_template`, `validate_workflow`, `vary_workflow`,
`list_workflow_slots`, `set_workflow_slot`, `workflow_deps`, `node_dependencies`,
`upload_file`, `free_memory`, `auth_status`, `partner_*`

**Do not use against this container** — these manage a local ComfyUI process and
local files, which a container deliberately does not expose:

| Tool | Why it does not apply |
|------|----------------------|
| `launch_comfyui`, `stop_comfyui`, `restart_comfyui` | ComfyUI's lifecycle is Docker's. Use `docker compose up/down/restart`. |
| `get_logs` | `docker compose logs comfyui` instead. |
| `install_node`, `update_comfyui`, `switch_comfyui_version` | Writes to a local checkout. Our updater already does the equivalent inside the image. |
| `download_model` | Writes to the CLI's own workspace models dir, **not** the container's `./models`. See below. |
| `nodes`, `node_dependencies`, `workflow_deps` | Need ComfyUI-Manager's `cm_cli` module. See below. |

### Node introspection: an upstream limitation

`nodes` and friends are the one group that cannot work here, and the reason is
worth being precise about rather than hand-waving.

`comfy-mcp` bundles a ComfyUI workspace so `comfy which` and every command that
resolves a path have something to resolve — that part works. Node listing then
fails with:

```
ComfyUI-Manager not found. 'cm-cli' command is not available.
```

comfy-cli probes for the `cm_cli` **module** (it runs `python -c "import
cm_cli"`), but current ComfyUI-Manager ships `cm-cli.py`, a hyphenated script,
not an importable `cm_cli` package. Running that script directly instead needs
ComfyUI-Manager's own requirements, which include `transformers` and
`matrix-nio` — a large install for an image that otherwise needs neither.

It is also not worth forcing. Node listing through a workspace reports the node
classes in the **baked checkout**, not the ones your running ComfyUI actually
has. Any custom node you installed in the `comfyui` container would be invisible
to it, so a green `nodes` result would be quietly misleading.

For the authoritative answer, ask the running server directly. This container
publishes `/object_info`, which lists every node class the live ComfyUI can
execute:

```bash
curl -s http://127.0.0.1:8188/object_info | jq 'keys | length'    # 963 here
```

If upstream fixes the `cm_cli` expectation, this becomes moot; the workspace
already in the image means only that one probe needs to start passing.

Two documented quirks worth knowing:

- `system_stats` and `free_memory` are **not** redirected by `COMFYUI_URL`; they
  describe whichever ComfyUI `comfy-cli` targets. On this setup they happened to
  be correct, but do not gate a remote run on them.
- Because the server's model dir and the container's are different directories,
  `download_model` will not put files where the container can see them. Download
  into `./models` on the host, or use ComfyUI's own Manager in the UI.

### Getting models in

The container mounts `./models`, so anything you place there before starting is
picked up:

```bash
# e.g. with huggingface-cli / hf
hf download stabilityai/stable-diffusion-xl-base-1.0 \
  sd_xl_base_1.0.safetensors --local-dir ./models/checkpoints
docker compose restart
curl -s http://127.0.0.1:8188/models/checkpoints
```

## Security

Two things to weigh, both real:

- The MCP server drives your GPU and writes to `./output`. Anything the agent
  generates lands in a directory you may later publish. Treat agent access as
  equivalent to shell access to that directory.
- ComfyUI's UI is unauthenticated. Do not expose port 8188 beyond localhost just
  to give an agent on another machine access — see the README on putting it
  behind a VPN or an authenticating proxy.
- `partner_generate` spends credits on hosted partner models. It is off by
  default and interlocked, but be aware it exists.

## Troubleshooting

| Symptom | Cause |
|---------|-------|
| `Bind for 0.0.0.0:8188 failed: port is already allocated` | A `ports:` entry was added to the stdio `comfy-mcp` service. It has no listening socket to publish, and 8188 is already taken by `comfyui`. Remove the `ports:` block from that service. |
| `comfy-mcp` container is "Up" but nothing responds | It was started with `up -d`, which leaves it blocked reading stdin. Use `docker compose --profile mcp run --rm comfy-mcp`, which attaches stdin. |
| Nothing appears after `docker compose up -d` | Expected: the MCP services are behind the `mcp` / `mcp-http` profiles and never start by default. |
| `"comfy" not found on PATH` | `COMFY_BIN` unset or wrong. Set it to an absolute path. |
| Server starts, every tool fails | Same as above — the handshake still succeeds. |
| `"Error executing tool <name>"` with no detail | An argument the tool does not accept. The generic message hides it; re-run the underlying `comfy <subcommand> --help` to see the real schema. `nodes` takes `action`/`query`, not `limit`. |
| `no_checkpoint_available` | `./models/checkpoints` is empty. Expected on a fresh clone. |
| `COMFYUI_URL ... is rejected` | Must be plain `http://host:port` — no `https://`, no path, no query. |
| Tool list empty in the client | Restart or reload the client after editing its config. |
| Generated files not where expected | Use `fetch_outputs(prompt_id, out_dir)` and name the directory. |

## Why a separate image

Worth stating explicitly, since it looks like an odd choice:

- The MCP server is **stdio**. It is spawned per session by the AI client, not
  run as a long-lived service, so there is no port for a compose service to
  expose. That is why it sits behind the `mcp` profile with `stdin_open` rather
  than being started by a plain `docker compose up`.
- It needs no GPU and no CUDA, so it is 216 MB instead of 11 GB.
- It is AGPL-3.0-or-later OR Commercial, while the ComfyUI image here is MIT.
  Keeping it separate avoids shipping a copyleft component inside this project's
  published artifact. The upstream source, and this repository's
  `Dockerfile.mcp`, are the corresponding source for that image.