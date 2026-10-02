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

Tested on this exact container (ComfyUI 0.38.0, torch 2.11.0+cu130, dual GPU):

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

That last row is the expected result on a fresh checkout: the submit path works,
there is just no checkpoint yet. Once `./models/checkpoints` holds a model,
generation works.

## Install

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

## Point it at the container

ComfyUI must be up first:

```bash
docker compose up -d
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8188/system_stats   # 200
```

`comfy-compose` publishes port 8188 on the host, which is exactly the address the
server defaults to, so usually no configuration is needed. Set
`COMFY_LOCAL_URL` only if you moved the port.

## Client configuration

`COMFY_BIN` is not optional in practice: MCP clients launch the server with their
own environment, which often does not include your shell `PATH`.

### Claude Code

`--env` must come before the `--` separator:

```bash
claude mcp add comfy-mcp --env COMFY_BIN="$(command -v comfy)" -- comfy-mcp
```

### Claude Desktop

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

### Cursor

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
| `"comfy" not found on PATH` | `COMFY_BIN` unset or wrong. Set it to an absolute path. |
| Server starts, every tool fails | Same as above — the handshake still succeeds. |
| `"Error executing tool <name>"` with no detail | An argument the tool does not accept. The generic message hides it; re-run the underlying `comfy <subcommand> --help` to see the real schema. `nodes` takes `action`/`query`, not `limit`. |
| `no_checkpoint_available` | `./models/checkpoints` is empty. Expected on a fresh clone. |
| `COMFYUI_URL ... is rejected` | Must be plain `http://host:port` — no `https://`, no path, no query. |
| Tool list empty in the client | Restart or reload the client after editing its config. |
| Generated files not where expected | Use `fetch_outputs(prompt_id, out_dir)` and name the directory. |

## Not in this repository

Deliberately not wired into `docker-compose.yml`:

- The server is **stdio**, spawned by the AI client on the host. Running it as a
  compose service would produce nothing useful — no client would connect to it.
- Baking it into this image would pull an AGPL component into a published
  artifact for no benefit.