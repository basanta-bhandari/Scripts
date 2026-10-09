# #github-keys #ssh-key: supply paths to your private keys at runtime.
GITHUB_SSH_KEY="${GITHUB_SSH_KEY:?Set GITHUB_SSH_KEY to your primary SSH key path}"
GITHUB_SSH_FALLBACK_KEY="${GITHUB_SSH_FALLBACK_KEY:?Set GITHUB_SSH_FALLBACK_KEY to your alternate SSH key path}"
eval "$(ssh-agent -s)" && ssh-add "$GITHUB_SSH_KEY"
ssh -T git@github.com
# If that fails, try the alternate key:
ssh-add "$GITHUB_SSH_FALLBACK_KEY"
ssh -T git@github.com
