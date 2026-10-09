#!/bin/bash
set -e
read dir_pos
echo "Enter your directory position from /home/(your_user) "

cd $dir_pos || {
  echo " Can't find repo"
  exit 1
}
echo "Deleting junk files....."
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

# Nuke and rebuild nukenv
echo "Deleting dirs with 'env' in them....."
rm -rf *env
python -m venv nukenv
source nukenv/bin/activate.fish
pip install -r requirements.txt

echo " Nuked & rebuilt enviornment"
