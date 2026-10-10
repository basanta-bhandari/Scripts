#!/usr/bin/env bash
  set -e

  rsync -a --delete \
    --exclude='.git/' \
    --exclude='.vercel/' \
    --exclude='node_modules/' \
    --exclude='.env' \
    --exclude='.env.local' \
    --exclude='.env*.local' \
    /home/b454/Desktop/Codex-Prjs/Portfolio/ \
    "/home/b454/Desktop/Desktop/Submitted- Prjs/Portfolio/"

  cd "/home/b454/Desktop/Desktop/Submitted- Prjs/Portfolio/"

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
