#!/bin/bash

set -e

REPO_DIR=~/Desktop/Submitted-\ Prjs/OS?
cd "$REPO_DIR" || {
  echo "❌ Can't find repo"
  exit 1
}

# Start ssh-agent and cache key
eval "$(ssh-agent -s)" >/dev/null 2>&1
echo "🔑 Enter SSH passphrase:"
ssh-add ~/.ssh/id_ed25519 2>/dev/null || ssh-add ~/.ssh/id_rsa 2>/dev/null || {
  echo "❌ Could not load SSH key"
  exit 1
}

# Ask for commit message
read -p "📝 Commit message: " -r MSG
if [ -z "$MSG" ]; then
  echo "❌ No commit message, aborting"
  exit 1
fi

# Stage everything
git add -A

# Commit
git commit -m "$MSG"

# Push
BRANCH=$(git branch --show-current)
git push -u origin "$BRANCH"

# Cleanup
kill "$SSH_AGENT_PID" 2>/dev/null

echo "✅ Pushed to origin/$BRANCH"
