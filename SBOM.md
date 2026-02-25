# Software Bill of Materials (SBOM)

## Project Overview

**Project Name**: ComfyUI Docker Setup  
**Project Version**: 1.0.0  
**Description**: Production-ready Docker setup for ComfyUI with GPU acceleration, auto-update, and API integration

## Components

### Base Image
- **Name**: Ubuntu 22.04
- **Version**: LTS
- **License**: Ubuntu License

### Core Software
- **ComfyUI**: Stable diffusion interface
  - **Version**: Latest from official repository
  - **License**: MIT License
- **Python**: Programming language
  - **Version**: 3.10+ (included with ComfyUI)
  - **License**: Python Software Foundation License
- **Docker**: Container platform
  - **Version**: 24.0+
  - **License**: Apache License 2.0

### Dependencies
- **NVIDIA CUDA**: GPU acceleration
  - **Version**: Latest compatible with RTX 2000 Ada
  - **License**: NVIDIA CUDA Toolkit License
- **git**: Version control
  - **Version**: 2.34+
  - **License**: GNU General Public License v2.0
- **cron**: Task scheduling
  - **Version**: Ubuntu default
  - **License**: GNU General Public License v2.0

### Configuration Files
- **Dockerfile**: Container build configuration
  - **License**: MIT License
- **docker-compose.yml**: Service orchestration
  - **License**: MIT License
- **docker-entrypoint.sh**: Container startup script
  - **License**: MIT License

## Security Components

### Environment Variables
- **HF_TOKEN**: HuggingFace API token
- **CIVITAI_API_KEY**: Civitai API key
- **AUTO_UPDATE**: Auto-update flag
- **UPDATE_SCHEDULE**: Update cron schedule

### Volume Mounts
- **models**: Model storage
- **input**: Input files
- **output**: Generated images
- **custom_nodes**: Custom nodes

## Security Measures

1. **Credential Management**: All API keys stored in .env file
2. **Git Exclusion**: .env excluded from git via .gitignore
3. **Runtime Loading**: API keys loaded only at container runtime
4. **No Hardcoded Secrets**: All credentials externalized

## Licensing

This project is licensed under the MIT License. All components are used under their respective licenses.

## Version Control

- **Repository**: https://github.com/HexRebuilt/comfyui-docker
- **Branch**: master
- **Last Updated**: 2026-02-25

## Compliance

This SBOM follows the NTIA Software Bill of Materials standard and includes all third-party components and their licenses.