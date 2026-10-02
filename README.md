# ComfyUI Docker

A containerised ComfyUI with GPU acceleration, self-update, and CI-published images.

Drive it from an AI agent over MCP with the official
[`Comfy-Org/comfy-mcp`](docs/MCP.md).

Based on the official ComfyUI repository: [Comfy-Org/ComfyUI](https://github.com/Comfy-Org/ComfyUI).

## Quick Start

The image is published to GitHub Container Registry, so no build is needed:

```bash
git clone https://github.com/HexRebuilt/Comfyui-docker.git
cd Comfyui-docker
docker compose up -d
```

Then open <http://localhost:8188>.

To set API keys, copy the example env file first:

```bash
cp .env.example .env
$EDITOR .env
docker compose up -d
```

Everything in `.env` is optional; the stack starts without it.

To build from source instead:

```bash
docker compose build       # requires the build: block to be uncommented
docker compose up -d
```

## Image

```
ghcr.io/hexrebuilt/comfyui-docker:latest
```

`linux/amd64` only. The image exists to run CUDA on an NVIDIA GPU, and there is
no useful arm64 target for that: aarch64 Jetson needs a different base image
(`nvcr.io/nvidia/l4t`) and Apple Silicon cannot run CUDA at all.

Tags follow the metadata-action convention: branch names, `vX.Y.Z` semver tags,
`sha-abcdef1` for a specific commit, and `latest` for the newest **release**.

`latest` moves only when you push a semver tag, never on a merge to `master`, so
a plain `docker compose pull` gets you a tagged release rather than untested
work off the default branch. Prereleases (`v1.1.0-rc1`) deliberately do not move
it.

Each published image carries an SBOM and a build provenance attestation. To
verify provenance:

```bash
docker buildx imagetools inspect ghcr.io/hexrebuilt/comfyui-docker:latest
```

## GPU Support Matrix

The base image is **CUDA 13.0 on Ubuntu 24.04**, with PyTorch built against
`cu130`. This is not arbitrary — CUDA 12.7 and earlier cannot target several
current GPUs at all:

| GPU | Compute capability | CUDA 12.1 (previous base) | CUDA 13 / cu130 (current) |
|-----|--------------------|---------------------------|--------------------------|
| RTX 2000 Ada | sm_89 | PTX JIT only | native |
| RTX 3090 / 4090 | sm_86 | native | native |
| RTX 5080 / 5090, RTX 5070 Ti | sm_120 | **unsupported** | native |

The previous image (`nvidia/cuda:12.1.0-cudnn8-runtime-ubuntu22.04`) pinned
PyTorch to the `cu121` wheel index, which stopped at torch 2.5.1 in October
2024. That combination cannot run Blackwell cards at all, and falls back to
slow PTX JIT even on Ada. Separately, ComfyUI's `comfy-kitchen` dependency
requires `cuBLASLt` 13.x, which only exists in CUDA 13+.

If you are on a GPU older than sm_75 (Maxwell, Pascal), note that CUDA 13
dropped support for those architectures. Such a card needs an older base image
than the one shipped here.

### Requirements

- NVIDIA driver on the host. Blackwell (RTX 50-series) needs driver 570+;
  Ada and Ampere need 525+. Check with `nvidia-smi`.
- The [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html),
  so `docker compose` can pass the GPU through.

## Configuration

All variables are optional. See `.env.example`.

| Variable | Default | Description |
|----------|---------|-------------|
| `AUTO_UPDATE` | `true` | Pull the latest ComfyUI at container start |
| `UPDATE_INTERVAL` | `24h` | How often to re-check while running; any `sleep` duration (`30m`, `6h`, `1d`) |
| `ENABLE_CRON` | `true` | Set `false` to skip the scheduler entirely |
| `HF_TOKEN` | — | HuggingFace token for gated models |
| `CIVITAI_API_KEY` | — | Read by custom nodes; ComfyUI core does not use it |
| `PUID` / `PGID` | `1000` | uid:gid the container runs as, for bind-mount ownership |

The scheduler reads `UPDATE_INTERVAL` at startup, so changing it takes effect on
the next `docker compose up -d` without a rebuild.

There is no cron daemon in the container. A real one requires root, and this
image deliberately runs unprivileged; instead a background loop re-checks on
`UPDATE_INTERVAL` and writes to `/var/log/comfyui-update.log`. The trade-off is
that the interval is not a calendar schedule, so "every 24h" drifts by the
uptime of the container. Restarting the container on a timer, or pulling a
fresh image, is the more predictable option.

## Volumes

| Host path | Container path | Contents |
|-----------|----------------|----------|
| `./models` | `/opt/ComfyUI/models` | Checkpoints, VAEs, LoRAs, controlnet |
| `./input` | `/opt/ComfyUI/input` | Workflow inputs |
| `./output` | `/opt/ComfyUI/output` | Generated images |
| `./custom_nodes` | `/opt/ComfyUI/custom_nodes` | Installed custom nodes |

These are bind mounts, so the container runs as `PUID:PGID` to keep them
writable. Set both to your host `id -u` / `id -g` if you hit permission errors.

## Auto-Update, and a Warning

With `AUTO_UPDATE=true` the container runs `git fetch` and a `git merge
--ff-only` against upstream ComfyUI, then re-syncs Python dependencies. This is
the feature that keeps the image aligned with upstream, and it is also the
largest supply-chain risk in this project:

- It executes code fetched from the internet at runtime, on your host, as a user
  who can write to `./output`.
- It bypasses the immutable, scanned artifact that CI publishes to GHCR. An
  auto-updating container is no longer the artifact that Trivy scanned.
- A malicious or compromised upstream commit runs with your permissions.

The update is a fast-forward only, so local edits to ComfyUI's own tree block
the update rather than being silently overwritten, and a failed update leaves
the running version untouched and still starts the container.

For anything exposed beyond your LAN, set `AUTO_UPDATE=false` and update
deliberately by pulling a new image. Also treat custom nodes as arbitrary code:
they are Python and run in-process.

## Security Posture

- Runs as an unprivileged user, not root.
- `cap_drop: ALL` and `no-new-privileges:true` in the compose file.
- No credentials baked into the image; `.env` is git- and docker-ignored.
- Third-party downloads in the build (none currently) are sha256-verified.
- CI runs hadolint, shellcheck, gitleaks, Trivy (filesystem and published
  image), and OpenSSF Scorecard on every push.
- Published images carry an SBOM and provenance attestation.

This container exposes an unauthenticated ComfyUI UI. Do not publish port 8188
to the internet. Put it behind a VPN or an authenticating reverse proxy.

## Known Scan Noise

Trivy reports four findings on every image scan, suppressed in `.trivyignore`:
`CVE-2025-47273` (setuptools), `CVE-2026-97687` / `CVE-2026-97689` (urllib3),
and `GHSA-6v7p-g79w-8964` (msgpack). All four are copies vendored *inside* pip
and setuptools rather than installed packages, so pip cannot update them
independently. Confirmed against the built image: `import msgpack` fails, and
the installed urllib3 and setuptools are already patched. Each suppression is
justified in the ignore file; remove them once pip or setuptools ships fixes.

## Health and Monitoring

```bash
docker compose ps                       # health status
docker compose logs -f comfyui
docker stats comfyui
```

The image declares a `HEALTHCHECK` against `/system_stats`, a cheap
side-effect-free endpoint. The compose file repeats it so `depends_on:
condition: service_healthy` works.

Check update history:

```bash
docker compose exec comfyui cat /var/log/comfyui-update.log
```

## Troubleshooting

### GPU not detected

```bash
docker compose exec comfyui nvidia-smi
docker compose exec comfyui python -c \
  "import torch; print(torch.__version__, torch.version.cuda, torch.cuda.is_available(), torch.cuda.get_device_name(0))"
```

If `nvidia-smi` fails inside the container, the NVIDIA Container Toolkit is not
installed or the daemon was not restarted after installing it. If `nvidia-smi`
works but torch reports `False`, the host driver is older than your GPU
requires — see the support matrix above.

### Permission errors on ./models or ./output

The container runs as `PUID:PGID` (default 1000). Match them to your host user:

```bash
echo "PUID=$(id -u)" >> .env
echo "PGID=$(id -g)" >> .env
docker compose up -d --force-recreate
```

### Auto-update not running

```bash
docker compose logs comfyui | grep -i 'scheduled\|updating'
docker compose exec comfyui cat /var/log/comfyui-update.log
```

No "Scheduled updates every ..." line means `AUTO_UPDATE`, `ENABLE_CRON`, or
`UPDATE_INTERVAL` is unset. Updates are skipped without failing the container if
the fetch fails or the tree has local modifications, so check the log rather
than assuming it is broken.

### ComfyUI will not start

```bash
docker compose logs comfyui | tail -50
```

Most often a dependency sync failure after an update, which the entrypoint
logs and then starts anyway. Pinning to a known-good image is the fastest
recovery:

```bash
docker compose pull && docker compose up -d
```

## MCP / AI Agents

The official [`Comfy-Org/comfy-mcp`](https://github.com/Comfy-Org/comfy-mcp) drives
this container: 39 tools covering generation, job monitoring, and introspection of
the nodes, models and templates your install actually has.

It is **stdio**, so it runs on your host and needs no GPU of its own. Because
port 8188 is published, the default `127.0.0.1:8188` already points at the
container.

It ships as its own 216 MB image (no CUDA, no GPU), so it is not baked into the
11 GB ComfyUI one:

```
ghcr.io/hexrebuilt/comfyui-docker-mcp:latest
```

Point an MCP client at the compose service — it reaches ComfyUI by service name,
with no host port involved:

```bash
docker compose --profile mcp pull
claude mcp add comfy-mcp -- docker compose --profile mcp run --rm -T comfy-mcp
```

CI rebuilds that image every Monday, so `pull` keeps it current. It deliberately
does not self-update at runtime the way ComfyUI does: it is spawned fresh per
MCP session, and swapping code under a live session is the failure mode to avoid.

Verified end-to-end from the published image: handshake clean, `system_stats`
reports ComfyUI 0.38.0, 484 templates listed. A handful of tools manage a
*local* ComfyUI process and do not apply to a container — see
**[docs/MCP.md](docs/MCP.md)** for the full supported/unsupported split, the
host-install alternative, and setup details.

## Development

| File | Purpose |
|------|---------|
| `Dockerfile` | Image build; `COMFYUI_REF` and `TORCH_INDEX_URL` are build args |
| `docker-entrypoint.sh` | Startup: update, HF auth, scheduler, exec |
| `docker-compose.yml` | Runtime configuration |
| `.github/workflows/security.yml` | Lint, secret scan, Trivy, Scorecard |
| `.github/workflows/build-and-push.yml` | Build, publish to GHCR, scan, attest |
| `comfyui-update.sh` | The updater, also callable by hand |
| `Dockerfile.mcp` | The MCP server image (separate, AGPL, no CUDA) |
| `docs/MCP.md` | Driving the container from an AI agent |
| `SBOM.md` | Verified component versions and known scan noise |

Before pushing a change, run the same checks CI does:

```bash
shellcheck docker-entrypoint.sh
hadolint Dockerfile
actionlint
docker compose config --quiet
```

`COMFYUI_REF` pins the ComfyUI branch or tag baked into the image. It defaults
to `master`; set it to a release tag such as `v0.38.0` for a reproducible build.

## Vibecoding Methodology

This setup was built with AI-assisted development, under human review. It is
provided as-is with no warranty. I do not take responsibility for anything that
breaks; if it breaks for me too, I will probably fix it, but do not count on
that.

## License

MIT — see [LICENSE](LICENSE).