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
It reaches ComfyUI over host networking, at `127.0.0.1:8188` — see
[Node introspection](#node-introspection-and-the-loopback-requirement) for why
that is not just the service name.

### Claude Code

```bash
claude mcp add comfy-mcp -- docker compose --profile mcp run --rm -T comfy-mcp
```

### opencode

opencode's `mcp` block cannot hold a `docker compose run` pipeline: `command`
must be an array of arguments, and that pipeline is not one. Point it at the
HTTP bridge instead, which is just a URL.

`~/.config/opencode/opencode.jsonc` (or `.json`), alongside your other servers:

```jsonc
{
  "mcp": {
    "comfyui": {
      "type": "remote",
      "url": "http://127.0.0.1:8081/mcp",
      "enabled": true,
      "timeout": 120000
    }
  }
}
```

`type` is required, and opencode rejects the whole config at startup rather than
half-working — a typo here means it will not launch at all. No `headers` block:
the bridge is loopback-only and needs no token by default. If you ever set
`MCP_BIND_ADDR` to a non-loopback address, add
`"headers": { "Authorization": "Bearer YOUR_TOKEN" }`.

The config is read once at startup and is **not** hot-reloaded, so quit and
restart opencode after editing it. `opencode mcp list` prints `connected` per
server, which is the quickest confirmation that the bridge is reachable.

This needs the bridge running. See `COMPOSE_PROFILES` above to have a plain
`docker compose up -d` start it.

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

Already wired into compose behind the `mcp-http` profile. **No token needed for
the default setup:**

```bash
docker compose --profile mcp-http up -d comfy-mcp-http
```

To avoid passing the flag every time, set the profile in `.env`:

```bash
COMPOSE_PROFILES=mcp-http
```

`.env` is gitignored, so that is per-deployment: a fresh clone starts ComfyUI
only, and your instance starts the bridge too. `COMPOSE_PROFILES` cannot be
replaced with a boolean such as `MCP_ENABLED=true` — a profile is a *name* that
something must activate, so putting `true` in the profile list leaves the
service off just as surely as `false`. Do not add the `mcp` profile here; that
one is the stdio server, which must be spawned by an MCP client rather than run
as a service.

It publishes `127.0.0.1:8081` — reachable from this machine and nothing else —
and starts unauthenticated because there is nothing to protect. Point a client
at it:

```json
{
  "mcpServers": {
    "comfy-mcp": {
      "type": "http",
      "url": "http://127.0.0.1:8081/mcp"
    }
  }
}
```

To publish it beyond this machine, set a token **and** the bind address:

```bash
echo "MCP_AUTH_TOKEN=$(openssl rand -hex 24)" >> .env
echo "MCP_BIND_ADDR=0.0.0.0"                    >> .env
docker compose --profile mcp-http up -d comfy-mcp-http
```

which adds the header to the client config:

```json
{ "type": "http", "url": "http://HOST:8081/mcp",
  "headers": { "Authorization": "Bearer YOUR_TOKEN" } }
```

### How the bridge decides whether a token is required

Exposure is decided by **where the port is published from the host**, not by
what the process binds. Inside a container the bridge must bind `0.0.0.0` for
the published port to reach it at all, so compose passes the host-side bind
separately as `MCP_PUBLIC_BIND`. Standalone runs fall back to `MCP_HTTP_HOST`.

| `MCP_PUBLIC_BIND` | No token | With token |
|---|---|---|
| `127.0.0.1` | starts, no auth | starts, auth |
| `0.0.0.0` or a LAN IP | **refuses to start** | starts, auth |

So the loopback-only guarantee is unchanged: publishing beyond this machine
without a token fails loudly instead of quietly exposing the GPU.

Verified over the network through compose: 39 tools listed, `system_stats`
reporting ComfyUI 0.38.0 / torch 2.11.0+cu130, 484 templates, and HTTP 401 for a
missing or wrong token versus 200 for the correct one.

### Reaching it from another machine

Set `MCP_BIND_ADDR=0.0.0.0` in `.env` to publish on the LAN. Read this first.

## Security: the network exposure

**This endpoint is a remote shell for your GPU.** comfy-mcp has no
authentication of its own, so the bridge adds it. A token is optional exactly
when the endpoint is reachable only from this machine, and mandatory otherwise:

- **`MCP_PUBLIC_BIND` is not loopback → a token is required.** The bridge
  refuses to start without one, so a typo cannot expose the GPU to the LAN.
- Tokens shorter than 16 characters are rejected.
- Comparison is constant-time (`hmac.compare_digest`).
- `MCP_ALLOW_ANONYMOUS` is accepted but no longer needed; a loopback bind
  permits anonymous access on its own.

What an authenticated caller can do: run GPU workloads, write files into the
container, and call `partner_generate`, which **spends real credits** on hosted
partner models. Treat the token like a password and an SSH key.

Also true of the existing setup, and worth repeating here:

- Port 8188 is an **unauthenticated ComfyUI UI**. This bridge gives network
  clients programmatic access to the same machine, so it is not a smaller
  exposure — it is a different shape of the same one.
- Anyone who can reach this can drive the GPU at your expense and consume disk
  with generated output.

Prefer, in order: leave it on `127.0.0.1` (the default) and reach it over SSH
or a Tailscale/WireGuard tunnel; or set a token and keep it on the LAN behind a
reverse proxy that terminates TLS; and never expose it to the internet directly.

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

Both images publish exactly one tag, `latest`, which moves on every merge to the
default branch. That is the tag compose pins and the tag watchtower compares, so
a daily watchtower poll picks up new images with no change on your side.

This was not always so. `comfyui-docker` used to publish `latest` only when a
`v*` release tag was pushed, on the reasoning that a release should never
silently swap the code an agent drives mid-session. In practice it just left the
stack behind: between releases, `docker compose pull` and watchtower fetched
nothing new, and `latest` still shipped `comfy-kitchen 0.2.36` against an
upstream requirement of `0.2.37`. The branch, semver and `sha-` tags that
briefly sat alongside `latest` have all been removed for the same reason — every
extra tag is another way to be pinned to the wrong image. Pin by digest if you
need reproducibility.

Three watchtower-specific things worth knowing:

- **The images are public.** `docker pull` works with no `docker login`, so
  watchtower needs no registry credentials. A private package would make its
  poll fail with 401 and silently never update.
- **Watchtower recreates a container from its stored config, not from
  `docker-compose.yml`.** If you change env vars, mounts or the healthcheck in
  compose, watchtower's recreated container will not have them. Run
  `docker compose up -d` yourself after editing compose; editing the file and
  waiting for watchtower does nothing.
- **The bridge is optional, so watchtower only sees it once it exists.** Watchtower
  updates running containers, not absent ones. It has `restart: unless-stopped`,
  so Docker restarts it on boot, but a first `docker compose up -d` without the
  profile will not create it. Set `COMPOSE_PROFILES=mcp-http` in `.env` for that.

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

### Node introspection, and the loopback requirement

`nodes` works, but only because of a non-obvious networking decision, so it is
worth writing down what broke first.

It failed with:

```
cql_no_graph: Refusing to fetch object_info from non-loopback host 'comfyui'
in local mode (potential SSRF). Use --where cloud for remote targets.
```

comfy-cli fetches `/object_info` for node listing and applies an SSRF guard: in
local mode the host must be loopback. `is_loopback_host()` in
`comfy_cli/cql/_net.py` accepts the literal string `localhost` or an address
`ipaddress` classifies as loopback, and it deliberately does **not** resolve
names. So a compose service name is refused, and so is a container IP. There is
no environment variable or flag to relax it.

The fix is to give the MCP containers a loopback address, which means host
networking (`network_mode: host`). Both MCP services therefore talk to ComfyUI
at `http://127.0.0.1:8188` — the host-published port — instead of over the
compose network. Two consequences to be aware of:

- If you change the `comfyui` port mapping, change `COMFYUI_URL` and
  `COMFY_LOCAL_URL` in both MCP services to match. They are no longer resolved
  by service name.
- `comfy-mcp-http` has no `ports:` mapping any more. With host networking the
  bridge binds the host directly, so `MCP_BIND_ADDR` is the address it binds
  (loopback by default) rather than a host-side publish address.

With that in place `nodes` reports against the **running** server, so it lists
the node classes your ComfyUI can actually execute, including custom nodes:

```bash
docker exec comfyui-docker-comfy-mcp-http-1 comfy nodes list   # 963 classes here
```

A caveat that is unchanged: `system_stats` and `free_memory` are not redirected
by `COMFYUI_URL` — they describe whichever ComfyUI comfy-cli targets. They are
correct here, but do not gate a remote run on them. And because the server's
model directory and the MCP container's are different directories,
`download_model` will not put files where ComfyUI can see them. Download into
`./models` on the host, or use ComfyUI's own Manager in the UI.

Two tools still do not work, for reasons unrelated to networking:

- `workflow_deps` needs ComfyUI-Manager inside the ComfyUI container. This
  repository does not install Manager, so there is nothing for it to query.
- `list_workflow_slots` and `list_workflow_notes` need a frontend-format
  workflow and reject an API-format export by design
  (`workflow_not_frontend_format`). Use `fetch_template`, which returns one.

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