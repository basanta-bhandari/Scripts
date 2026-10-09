#!/bin/bash
set -e

cd ~/Desktop/Submitted-\ Prjs/OS? || {
  echo "❌ Can't find repo"
  exit 1
}

# Nuke caches, eggs, dist, build
find . -maxdepth 10 \( \
  -type d -name __pycache__ -o \
  -type d -name "*.egg-info" -o \
  -type d -name dist -o \
  -type d -name build -o \
  -type d -name .eggs -o \
  -type d -name .pytest_cache -o \
  -type d -name .mypy_cache -o \
  -type f -name "*.pyc" -o \
  -type f -name "*.pyo" -o \
  -type f -name "*.whl" \
  \) -exec rm -rf {} + 2>/dev/null

# Nuke and rebuild outenv
rm -rf outenv testenv
python -m venv outenv
source outenv/bin/activate
pip install -r requirements.txt

echo "✅ Nuked & rebuilt outenv"
