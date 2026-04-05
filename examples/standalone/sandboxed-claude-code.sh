#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE_ROOT="${XDG_CACHE_HOME:-$HOME/.cache}/nix-apple-sandbox/standalone-claude-code"
HASH_INPUT="$(shasum -a 256 "$SCRIPT_DIR/Containerfile" "$SCRIPT_DIR/entrypoint.sh" | shasum -a 256 | awk '{print $1}')"
CONFIG_HASH="${HASH_INPUT:0:12}"
IMAGE_TAG="standalone-claude-code:${CONFIG_HASH}"
MARKER_PATH="$CACHE_ROOT/.built-${CONFIG_HASH}"

require_container() {
  if ! command -v container >/dev/null 2>&1; then
    echo "error: Apple container CLI not found in PATH" >&2
    exit 1
  fi
}

ensure_container_system() {
  if ! container system status >/dev/null 2>&1; then
    container system start --enable-kernel-install >/dev/null
  fi
}

ensure_image() {
  mkdir -p "$CACHE_ROOT"

  if [[ -f "$MARKER_PATH" ]]; then
    return 0
  fi

  container build -t "$IMAGE_TAG" "$SCRIPT_DIR"
  touch "$MARKER_PATH"
}

main() {
  local workspace_dir
  local -a run_args

  require_container
  ensure_container_system
  ensure_image

  workspace_dir="$(pwd -P)"
  run_args=(run --rm -it --volume "$workspace_dir:/workspace")

  if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    run_args+=(--env "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}")
  fi

  run_args+=("$IMAGE_TAG" claude)

  if (($# > 0)); then
    run_args+=("$@")
  fi

  container "${run_args[@]}"
}

main "$@"
