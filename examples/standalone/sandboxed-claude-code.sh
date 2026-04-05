#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE_ROOT="${XDG_CACHE_HOME:-$HOME/.cache}/nix-apple-sandbox/standalone-claude-code"
HASH_INPUT="$(shasum -a 256 "$SCRIPT_DIR/Containerfile" "$SCRIPT_DIR/entrypoint.sh" | shasum -a 256 | awk '{print $1}')"
CONFIG_HASH="${HASH_INPUT:0:12}"
IMAGE_TAG="standalone-claude-code:${CONFIG_HASH}"
MARKER_PATH="$CACHE_ROOT/.built-${CONFIG_HASH}"
CONTAINER_CLI=""
MINIMUM_CONTAINER_VERSION="0.10.0"

version_gte() {
  local lhs=$1
  local rhs=$2
  local idx lhs_part rhs_part
  local -a lhs_parts=()
  local -a rhs_parts=()

  IFS=. read -r -a lhs_parts <<<"$lhs"
  IFS=. read -r -a rhs_parts <<<"$rhs"

  for idx in 0 1 2; do
    lhs_part="${lhs_parts[$idx]:-0}"
    rhs_part="${rhs_parts[$idx]:-0}"
    lhs_part="${lhs_part%%[^0-9]*}"
    rhs_part="${rhs_part%%[^0-9]*}"
    lhs_part="${lhs_part:-0}"
    rhs_part="${rhs_part:-0}"

    if ((10#$lhs_part > 10#$rhs_part)); then
      return 0
    fi

    if ((10#$lhs_part < 10#$rhs_part)); then
      return 1
    fi
  done

  return 0
}

require_container() {
  local detected_cli detected_version formula_cli formula_version

  formula_cli="/opt/homebrew/opt/container/bin/container"
  detected_cli="$(command -v container || true)"
  detected_version=""

  if [[ -n "$detected_cli" ]]; then
    detected_version="$("$detected_cli" --version 2>/dev/null | awk '/container CLI version/ { print $4; exit }')"
    if [[ -n "$detected_version" ]] && version_gte "$detected_version" "$MINIMUM_CONTAINER_VERSION"; then
      CONTAINER_CLI="$detected_cli"
      return 0
    fi
  fi

  formula_version=""
  if [[ -x "$formula_cli" ]]; then
    formula_version="$("$formula_cli" --version 2>/dev/null | awk '/container CLI version/ { print $4; exit }')"
    if [[ -n "$formula_version" ]] && version_gte "$formula_version" "$MINIMUM_CONTAINER_VERSION"; then
      CONTAINER_CLI="$formula_cli"
      if [[ -n "$detected_cli" ]] && [[ "$detected_cli" != "$formula_cli" ]]; then
        echo "warning: ignoring outdated container CLI at $detected_cli (found ${detected_version:-unknown}); using $formula_cli (${formula_version})" >&2
      fi
      return 0
    fi
  fi

  if [[ -n "$detected_cli" ]]; then
    echo "error: container CLI at $detected_cli is too old (found ${detected_version:-unknown}; need >= $MINIMUM_CONTAINER_VERSION)" >&2
    echo "hint: remove the legacy Homebrew cask or update PATH to prefer /opt/homebrew/opt/container/bin/container" >&2
    exit 1
  fi

  echo "error: Apple container CLI not found in PATH" >&2
  exit 1
}

ensure_container_system() {
  if ! "$CONTAINER_CLI" system status >/dev/null 2>&1; then
    "$CONTAINER_CLI" system start --enable-kernel-install >/dev/null
  fi
}

ensure_image() {
  mkdir -p "$CACHE_ROOT"

  if [[ -f "$MARKER_PATH" ]]; then
    return 0
  fi

  "$CONTAINER_CLI" build -t "$IMAGE_TAG" "$SCRIPT_DIR"
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

  "$CONTAINER_CLI" "${run_args[@]}"
}

main "$@"
