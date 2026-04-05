#!/usr/bin/env bash
set -euo pipefail

CACHE_ROOT="${XDG_CACHE_HOME:-$HOME/.cache}/nix-apple-sandbox"

usage() {
  cat <<'EOF'
usage: sandbox-ctl.sh <command> [args]

commands:
  status
  rebuild
  clean
  list
  stop-all
  logs NAME
  disk
EOF
}

require_container() {
  if ! command -v container >/dev/null 2>&1; then
    echo "error: container CLI not found" >&2
    exit 1
  fi
}

supports_subcommand() {
  local output status

  set +e
  output="$("$@" --help 2>&1)"
  status=$?
  set -e

  if ((status == 0)); then
    return 0
  fi

  case "$output" in
    *"unknown command"*|*"unrecognized command"*|*"No help topic"*)
      return 1
      ;;
  esac

  return 0
}

run_image_prune() {
  if supports_subcommand container image prune; then
    container image prune -f
  else
    container images prune -f
  fi
}

run_disk_report() {
  if supports_subcommand container system df; then
    container system df
  else
    container images
  fi
}

cache_tags() {
  if [[ ! -d "$CACHE_ROOT" ]]; then
    return 0
  fi

  local sandbox_dir marker hash sandbox_name

  for sandbox_dir in "$CACHE_ROOT"/*; do
    [[ -d "$sandbox_dir" ]] || continue
    sandbox_name="$(basename "$sandbox_dir")"

    for marker in "$sandbox_dir"/.built-*; do
      [[ -f "$marker" ]] || continue
      hash="${marker##*.built-}"
      printf '%s:%s\n' "$sandbox_name" "$hash"
    done
  done
}

cmd_status() {
  require_container

  echo "== container system =="
  container system status || true
  echo

  echo "== sandbox cache =="
  if [[ -d "$CACHE_ROOT" ]]; then
    find "$CACHE_ROOT" -maxdepth 2 \( -name 'Containerfile' -o -name '.built-*' \) | sort || true
  else
    echo "(empty)"
  fi
  echo

  echo "== cached image tags =="
  cache_tags || true
}

cmd_rebuild() {
  if [[ -d "$CACHE_ROOT" ]]; then
    find "$CACHE_ROOT" -type f -name '.built-*' -delete
  fi
}

cmd_clean() {
  require_container

  local tag
  while IFS= read -r tag; do
    [[ -n "$tag" ]] || continue
    container image rm "$tag" >/dev/null 2>&1 || true
  done < <(cache_tags)

  rm -rf "$CACHE_ROOT"
  run_image_prune || true
}

cmd_list() {
  require_container
  container list
}

cmd_stop_all() {
  require_container

  local ids
  ids="$(container list --quiet 2>/dev/null || true)"
  if [[ -z "$ids" ]]; then
    echo "no running containers"
    return 0
  fi

  # shellcheck disable=SC2086
  container stop $ids
}

cmd_logs() {
  require_container

  if [[ $# -ne 1 ]]; then
    echo "error: logs requires a container name" >&2
    exit 1
  fi

  container logs "$1"
}

cmd_disk() {
  require_container
  run_disk_report || true
}

main() {
  local command="${1:-}"

  case "$command" in
    status)
      shift
      cmd_status "$@"
      ;;
    rebuild)
      shift
      cmd_rebuild "$@"
      ;;
    clean)
      shift
      cmd_clean "$@"
      ;;
    list)
      shift
      cmd_list "$@"
      ;;
    stop-all)
      shift
      cmd_stop_all "$@"
      ;;
    logs)
      shift
      cmd_logs "$@"
      ;;
    disk)
      shift
      cmd_disk "$@"
      ;;
    ""|-h|--help|help)
      usage
      ;;
    *)
      echo "error: unknown command: $command" >&2
      usage >&2
      exit 1
      ;;
  esac
}

main "$@"
