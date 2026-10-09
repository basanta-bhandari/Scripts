#!/usr/bin/env bash
set -euo pipefail

# --------------------------------------------------------------
# 0️⃣  System‑level dependencies for Arch / CachyOS (run once)
# --------------------------------------------------------------
#   • base-devel   – gcc, make, cmake, etc. (covers build‑essential)
#   • git          – clone the repo
#   • python‑pip   – Hugging‑Face downloader
#   • nvidia-dkms  – driver + CUDA runtime for the MX30
# --------------------------------------------------------------
sudo pacman -Sy --noconfirm \
    base-devel \
    cmake \
    git \
    python-pip \
    nvidia-dkms   # pulls in the correct driver & libcuda.so

# Optional: verify the driver is active
# nvidia-smi     # should show the MX30 and a CUDA version

# --------------------------------------------------------------
# 1️⃣  Install the lightweight llama.cpp runtime (CPU + CUDA)
# --------------------------------------------------------------
git clone --depth 1 https://github.com/ggerganov/llama.cpp ~/llama.cpp
cd ~/llama.cpp
mkdir -p build && cd build
cmake .. -DLLAMA_CUDA=ON -DLLAMA_NATIVE=ON   # enable MX30 off‑load
make -j$(nproc)
cd ../../

# --------------------------------------------------------------
# 2️⃣  Pull the 4‑billion‑parameter Qwen 3.5 model (GGUF‑Q4_K_M)
# --------------------------------------------------------------
pip install --quiet huggingface_hub
HF_REPO="unsloth/Qwen3.5-4B-GGUF"
HF_FILE="Qwen3.5-4B-GGUF-Q4_K_M.gguf"
mkdir -p ~/models
huggingface-cli download $HF_REPO $HF_FILE --local-dir ~/models --quiet

# --------------------------------------------------------------
# 3️⃣  Run the model
# --------------------------------------------------------------
# -ngl 0 → pure‑CPU (quietest)
# -ngl 1 → one GPU layer for a tiny speed boost (still low fan)
# Adjust -c (context window) as you like; 4096 is a safe default.
~/llama.cpp/build/main \
    -m ~/models/$HF_FILE \
    -c 4096 \
    -ngl 0   # change to -ngl 1 if you want a single GPU layer

