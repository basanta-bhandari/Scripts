#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
base_iso="$project_dir/cache/alpine-standard-3.24.2-x86_64.iso"
headless_overlay="$project_dir/cache/headless.apkovl.tar.gz"
output_iso="$project_dir/out/alpine-headless-rescue-3.24.2-x86_64.iso"
xorriso_bin="$project_dir/vendor/usr/bin/xorriso"

(
  cd "$project_dir/cache"
  sha256sum -c alpine-standard-3.24.2-x86_64.iso.sha256
  sha512sum -c headless.apkovl.tar.gz.sha512
)

export LD_LIBRARY_PATH="$project_dir/vendor/usr/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

"$xorriso_bin" \
  -indev "$base_iso" \
  -outdev "$output_iso" \
  -boot_image any replay \
  -map "$headless_overlay" /headless.apkovl.tar.gz \
  -map "$project_dir/overlay/authorized_keys" /authorized_keys \
  -map "$project_dir/overlay/opt-out" /opt-out \
  -map "$project_dir/overlay/ssh_host_ed25519_key" /ssh_host_ed25519_key \
  -commit \
  -end

sha256sum "$output_iso" >"$output_iso.sha256"
printf 'Built %s\n' "$output_iso"
