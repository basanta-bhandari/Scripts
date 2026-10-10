#!/usr/bin/env bash
#THIS IS SUPPOSED TO BE ON $PATH AS "RUN" COMMAND
set -euo pipefail

if (( $# == 0 )); then
    printf 'Usage: run <script.sh|script.py> [arguments...]\n' >&2
    exit 2
fi

filename=$1
shift

case "$filename" in
    */*)
        printf 'run: provide a filename from ~/scripts, not a path: %s\n' "$filename" >&2
        exit 2
        ;;
esac

case "$filename" in
    *.sh|*.py) ;;
    *)
        printf 'run: unsupported file type: %s (expected .sh or .py)\n' "$filename" >&2
        exit 2
        ;;
esac

scripts_dir="$HOME/scripts"
if ! cd -- "$scripts_dir"; then
    printf 'run: cannot access %s\n' "$scripts_dir" >&2
    exit 1
fi

if [[ ! -f "$filename" ]]; then
    printf 'run: script not found: %s/%s\n' "$scripts_dir" "$filename" >&2
    exit 1
fi

case "$filename" in
    *.sh)
        chmod +x -- "$filename"
        exec "./$filename" "$@"
        ;;
    *.py)
        exec python3 -- "$filename" "$@"
        ;;
esac
