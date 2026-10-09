#!/bin/bash
set -e

# #laptop-data: supply the package repository path at runtime.
PROJECT_DIR="${PROJECT_DIR:?Set PROJECT_DIR to the package repository}"
# #pypi-key: supply the token in the environment; never store it in this file.
PYPI_TOKEN="${PYPI_TOKEN:?Set PYPI_TOKEN to your PyPI API token}"
cd "$PROJECT_DIR" || {
  echo "❌ Can't find repo"
  exit 1
}

# Ask for version
CURRENT=$(grep 'version = ' pyproject.toml | head -1 | sed 's/version = "\(.*\)"/\1/')
echo "📌 Current version: $CURRENT"
read -p "📝 New version: " -r VER
if [ -z "$VER" ]; then
  echo "❌ No version, aborting"
  exit 1
fi

# Update pyproject.toml
sed -i "s/version = \"$CURRENT\"/version = \"$VER\"/" pyproject.toml
echo "✅ Set version to $VER"

# Activate venv
source outenv/bin/activate
pip install build twine --quiet

# Clean & build
rm -rf dist/ build/ src/*.egg-info
python -m build

# Upload
TWINE_USERNAME=__token__ TWINE_PASSWORD="$PYPI_TOKEN" python -m twine upload dist/*

echo "✅ Uploaded v$VER to PyPI"
