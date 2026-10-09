#!/bin/bash

# GitHub SSH & GPG Key Setup Script

# 1. Generate GPG Key
gpg --full-generate-key

# Get GPG Key ID (extracts automatically)
GPG_KEY_ID=$(gpg --list-secret-keys --keyid-format=long | grep sec | awk '{print $2}' | cut -d'/' -f2 | head -1)

echo "Your GPG Key ID: $GPG_KEY_ID"
echo "Export this public key and add to GitHub (Settings > SSH and GPG keys > New GPG key):"
gpg --armor --export "$GPG_KEY_ID"

# Configure Git for GPG signing
echo "Configuring git for GPG signing..."
git config --global user.signingkey "$GPG_KEY_ID"
git config --global commit.gpgsign true

# 2. Generate SSH Key
ssh-keygen -t ed25519 -C "your_email@example.com"

# Start SSH agent
eval "$(ssh-agent -s)"

# Add SSH key to agent
ssh-add ~/.ssh/id_ed25519

# Copy public key to clipboard (Linux)
echo "Your SSH Public Key (copy to GitHub > SSH and GPG keys > New SSH key):"
cat ~/.ssh/id_ed25519.pub | xclip -selection clipboard 2>/dev/null || cat ~/.ssh/id_ed25519.pub

# 3. Configure SSH for GitHub
echo "Host github.com
  AddKeysToAgent yes
  IdentityFile ~/.ssh/id_ed25519" > ~/.ssh/config

echo "Setup complete! Add both keys to GitHub."
