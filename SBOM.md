# Software Bill of Materials

Hand-maintained summary. The authoritative, machine-readable SBOM is generated
at build time and attached to every published image:

```bash
docker buildx imagetools inspect ghcr.io/hexrebuilt/comfyui-docker:latest --format '{{ json .Provenance }}'
```

or download the attestation from the GHCR package page.

Versions below were read from a built image, not assumed.

## Project

| Field | Value |
|-------|-------|
| Repository | https://github.com/HexRebuilt/Comfyui-docker |
| Branch | `master` |
| Image | `ghcr.io/hexrebuilt/comfyui-docker` |
| License | MIT (see [LICENSE](LICENSE)) |

## Base image

| Component | Version | License |
|-----------|---------|---------|
| `nvidia/cuda:13.0.3-cudnn-runtime-ubuntu24.04` | CUDA 13.0.3 | NVIDIA CUDA Toolkit License |
| Ubuntu | 24.04.4 LTS | Ubuntu License |
| cuDNN | 9 (bundled in base image) | NVIDIA cuDNN License |

The base image ships the CUDA runtime. PyTorch brings its own CUDA libraries as
Python wheels, so the two are independent.

## Runtime OS packages

| Package | Version | Purpose |
|---------|---------|---------|
| openssl | 3.0.13-0ubuntu3.16 | TLS; explicitly upgraded past CVE-2026-45447, CVE-2026-84782 |
| git | 2.43.0 | Updater (`git fetch` + `git merge --ff-only`) |
| curl | 8.5.0 | HF CLI downloads, HEALTHCHECK probe |
| tini | 0.19.0 | PID 1, reaps children and forwards signals |
| ca-certificates | 20250917 | TLS trust store |

## Python environment

Python 3.12.3 in a venv at `/opt/venv`, pip 26.2.1, setuptools 81.0.0.
104 packages total. Key ones:

| Package | Version | Notes |
|---------|---------|-------|
| torch | 2.11.0+cu130 | cu130 wheels; sm_75 through sm_120 |
| torchvision | 0.26.0+cu130 | declares `torch==2.11.0` |
| torchaudio | 2.11.0+cu130 | last cu130 release with a matching torch |
| transformers | 5.18.0 | |
| comfy-kitchen | 0.2.36 | requires cuBLASLt 13.x, i.e. CUDA 13+ |
| comfy-aimdo | 0.5.5 | |
| comfyui-frontend-package | 1.53.10 | pinned by ComfyUI |
| comfyui-workflow-templates | 0.11.73 | pinned by ComfyUI |
| av | 19.0.0 | |
| numpy | 2.5.2 | |
| safetensors | 0.8.0 | |

Torch is pinned to 2.11.0 rather than the newest available because the cu130
torchaudio index stops at 2.11.0; a newer torch would leave torchaudio
uninstallable.

`wheel` is deliberately removed: nothing builds a wheel at runtime and it
carries CVE-2026-24049. `pip` is kept because the updater installs packages.

## Application

| Component | Version | License |
|-----------|---------|---------|
| ComfyUI | `master` @ `1b883bea` (see `v0.38.0`) | GPL-3.0 |
| ComfyUI frontend | 1.53.10 | GPL-3.0 |

ComfyUI is cloned from `https://github.com/Comfy-Org/ComfyUI` and can float with
`master` unless `COMFYUI_REF` pins a tag. The updater advances it at runtime.

## Credentials

No credentials are baked into the image. `HF_TOKEN` and `CIVITAI_API_KEY` are
read from the environment at runtime; `.env` is excluded by both `.gitignore`
and `.dockerignore`.

## Known scanner noise

Four findings appear in every image scan and are suppressed in `.trivyignore`:

| Finding | Package reported | Why it is not actionable |
|---------|------------------|--------------------------|
| CVE-2025-47273 | setuptools 70.3.0 | vendored copy; real setuptools is 81.0.0 |
| CVE-2026-97687, CVE-2026-97689 | urllib3 2.7.0 | vendored copy; real urllib3 is 2.8.0 |
| GHSA-6v7p-g79w-8964 | msgpack 1.1.2 | vendored inside pip; `import msgpack` fails |

Each was confirmed against the built image rather than assumed. Revisit when pip
or setuptools ships a release carrying the fixes.

## Lower-severity findings

The image scan is configured for HIGH and CRITICAL, and reports none. For
completeness, at LOW/MEDIUM the image has **fewer** findings than its own base
image: 64 versus 94 for `nvidia/cuda:13.0.3-cudnn-runtime-ubuntu24.04`, because
upgrading openssl and the Python packages resolves 34 that the base carries.

Three findings are attributable to this project rather than the base image:

| Finding | Severity | Package | Installed | Fixed in |
|---------|----------|---------|-----------|----------|
| CVE-2026-59890 | MEDIUM | setuptools | 81.0.0 | 83.0.0 |
| CVE-2025-3000 | LOW | torch | 2.11.0+cu130 | 2.13.0 |
| CVE-2026-97688 | MEDIUM | urllib3 | 2.7.0 (vendored) | 2.8.0 |

None can be resolved as things stand:

- setuptools and torch are capped by torch's own `setuptools<82` requirement.
- torch 2.13.0 would clear CVE-2025-3000, but the cu130 torchaudio index stops
  at 2.11.0, so upgrading torch means dropping torchaudio.
- The urllib3 finding is the vendored copy described above.

CVE-2025-3000 deserves a note: its Trivy title reads "A vulnerability classified
as critical has been found in PyTorch 2.6.0", which is misleading. It is a
`safety`-sourced advisory about an unsafe-weight-loading code-execution issue in
torch.load, rated LOW here, and the title refers to the version the advisory was
written against rather than this image.

## Prior SBOM

The previous version of this file described Ubuntu 22.04, Python 3.10+, and a
CUDA version "latest compatible with RTX 2000 Ada", and listed `huggingface-cli`
as a component. None of that matched the image. This version is generated from
the built artifact.