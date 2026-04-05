#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE_ROOT="${XDG_CACHE_HOME:-$HOME/.cache}/nix-apple-sandbox/standalone-nix-apple-sandbox"
HASH_INPUT="$(shasum -a 256 "$SCRIPT_DIR/Containerfile" "$SCRIPT_DIR/entrypoint.sh" | shasum -a 256 | awk '{print $1}')"
CONFIG_HASH="${HASH_INPUT:0:12}"
IMAGE_TAG="standalone-nix-apple-sandbox:${CONFIG_HASH}"
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
  local command_name
  local env_name
  local seen_env
  local seen
  local should_drop
  local -a run_args
  local -a forwarded_envs=()
  local -a auto_forwarded_envs=()
  local -a dropped_forwarded_envs=()

  command_name="bash"

  if (($# > 0)) && [[ "$1" == "--" ]]; then
    shift
  fi

  if (($# > 0)); then
    command_name="${1##*/}"
  fi

  if [[ "${NIX_APPLE_SANDBOX_NO_AUTO_PASS_ENV:-0}" != "1" ]]; then
    case "$command_name" in
      claude)
        auto_forwarded_envs=(ANTHROPIC_API_KEY)
        ;;
      codex)
        auto_forwarded_envs=(OPENAI_API_KEY)
        ;;
      gemini)
        auto_forwarded_envs=(GEMINI_API_KEY GOOGLE_API_KEY)
        ;;
    esac
  fi

  if [[ -n "${NIX_APPLE_SANDBOX_PASS_ENV:-}" ]]; then
    # Space-separated env var names to forward from the host.
    # Example: NIX_APPLE_SANDBOX_PASS_ENV="ANTHROPIC_API_KEY OPENAI_API_KEY"
    read -r -a forwarded_envs <<<"${NIX_APPLE_SANDBOX_PASS_ENV}"
  fi

  for env_name in "${auto_forwarded_envs[@]-}"; do
    [[ -n "$env_name" ]] || continue
    seen=0

    for seen_env in "${forwarded_envs[@]-}"; do
      if [[ "$seen_env" == "$env_name" ]]; then
        seen=1
        break
      fi
    done

    if (( ! seen )); then
      forwarded_envs+=("$env_name")
    fi
  done

  if [[ -n "${NIX_APPLE_SANDBOX_DROP_PASS_ENV:-}" ]]; then
    read -r -a dropped_forwarded_envs <<<"${NIX_APPLE_SANDBOX_DROP_PASS_ENV}"
  fi

  require_container
  ensure_container_system
  ensure_image

  workspace_dir="$(pwd -P)"
  run_args=(run --rm -it --volume "$workspace_dir:/workspace")

  for env_name in "${forwarded_envs[@]-}"; do
    [[ -n "$env_name" ]] || continue
    should_drop=0

    for seen_env in "${dropped_forwarded_envs[@]-}"; do
      if [[ "$seen_env" == "$env_name" ]]; then
        should_drop=1
        break
      fi
    done

    if (( should_drop )); then
      continue
    fi

    if [[ -n "${!env_name:-}" ]]; then
      run_args+=(--env "$env_name=${!env_name}")
    fi
  done

  run_args+=("$IMAGE_TAG")

  if (($# > 0)); then
    run_args+=("$@")
  else
    run_args+=(bash)
  fi

  container "${run_args[@]}"
}

main "$@"
