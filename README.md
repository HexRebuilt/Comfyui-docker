# ComfyUI Docker Setup

A production-ready Docker setup for ComfyUI with auto-update, GPU support, and API key integration.

## Features

- **GPU Acceleration**: NVIDIA CUDA support with various NVIDIA GPUs
- **Auto-Update**: Automatic git updates every 4 AM via cron
- **API Integration**: HuggingFace and Civitai API key support via .env file
- **Persistence**: Volume mounts for models, input, output, and custom nodes
- **Security**: No hardcoded secrets, all credentials via environment variables

## Official Repository

This setup is based on the official ComfyUI repository: [https://github.com/Comfy-Org/ComfyUI](https://github.com/Comfy-Org/ComfyUI)

## Vibecoding Methodology

This entire setup was created using vibecoding methodology - an AI-assisted development approach that combines automated code generation with human oversight to create production-ready software solutions.

## Quick Start

1. **Clone and build:**
   ```bash
   git clone https://github.com/HexRebuilt/comfyui-docker
   cd comfyui-docker
   docker compose build
   docker compose up -d
   ```

2. **Configure API keys:**
   ```bash
   cp .env.example .env
   # Edit .env and add your keys:
   # HF_TOKEN=hf_xxxxx
   # CIVITAI_API_KEY=xxxxx
   ```

3. **Access UI:**
   - Open http://localhost:8188

## Configuration

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `HF_TOKEN` | HuggingFace API token | - |
| `CIVITAI_API_KEY` | Civitai API key | - |
| `AUTO_UPDATE` | Enable auto-updates | `true` |
| `UPDATE_SCHEDULE` | Cron schedule for updates | `0 4 * * *` |

### Volumes

- `./models:/opt/ComfyUI/models` - Model storage
- `./input:/opt/ComfyUI/input` - Input files
- `./output:/opt/ComfyUI/output` - Generated images
- `./custom_nodes:/opt/ComfyUI/custom_nodes` - Custom nodes

## Security

- All credentials stored in `.env` file
- `.env` excluded from git via `.gitignore`
- No hardcoded secrets in code
- API keys only loaded at runtime

## Troubleshooting

### GPU Not Detected
```bash
# Check GPU status
docker exec comfyui nvidia-smi

# Ensure NVIDIA drivers installed
sudo apt install nvidia-driver-470
```

### Auto-Update Not Working
```bash
# Check cron logs
docker exec comfyui cat /var/log/comfyui-update.log

# Restart cron service
docker exec comfyui service cron restart
```

## API Key Setup

### HuggingFace
1. Get token from https://huggingface.co/settings/tokens
2. Add to `.env`: `HF_TOKEN=hf_xxxxx`
3. Auto-login on startup

### Civitai
1. Get API key from https://civitai.com/settings/api
2. Add to `.env`: `CIVITAI_API_KEY=xxxxx`

## Monitoring

### Logs
```bash
docker logs comfyui --tail 50 -f
```

### Resource Usage
```bash
docker stats comfyui
```

## Backup Strategy

1. **Models**: Regular rsync to backup location
2. **Outputs**: Automated cleanup for old files
3. **Configuration**: Git version control for all configs

## License

This project is licensed under the MIT License - see the LICENSE file for details.

## Support

- Issues: https://github.com/HexRebuilt/comfyui-docker/issues
- Documentation: https://github.com/HexRebuilt/comfyui-docker/wiki

---

**Note**: This setup is optimized for production use with security and maintainability in mind.
