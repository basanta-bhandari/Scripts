#!/usr/bin/env bash
  set -e

  # #laptop-data: supply your source and destination repository paths.
  PORTFOLIO_SOURCE="${PORTFOLIO_SOURCE:?Set PORTFOLIO_SOURCE to your source directory}"
  PORTFOLIO_DEST="${PORTFOLIO_DEST:?Set PORTFOLIO_DEST to your destination repository}"

  rsync -a --delete \
    --exclude='.git/' \
    --exclude='.vercel/' \
    --exclude='node_modules/' \
    --exclude='.env' \
    --exclude='.env.local' \
    --exclude='.env*.local' \
    "$PORTFOLIO_SOURCE/" \
    "$PORTFOLIO_DEST/"

  cd "$PORTFOLIO_DEST"

  read -r -p "Commit message: " commit_message

  if [ -z "$commit_message" ]; then
    echo "Commit cancelled: a message is required."
    exit 1
  fi

  git add .

  if git diff --cached --quiet; then
    echo "No changes to commit."
    exit 0
  fi

  git commit -m "$commit_message"
  git push
