{ pkgs }:
let
  lib = pkgs.lib;

  defaultAptPackages = [
    "curl"
    "wget"
    "git"
    "jq"
    "ca-certificates"
    "build-essential"
    "openssh-client"
    "ripgrep"
    "gawk"
    "findutils"
    "diffutils"
    "sed"
    "grep"
    "gzip"
    "unzip"
    "tar"
    "procps"
  ];

  sortUnique = values: lib.sort builtins.lessThan (lib.unique values);

  renderEnvLines = envVars:
    let
      names = lib.sort builtins.lessThan (builtins.attrNames envVars);
    in lib.concatStringsSep "\n" (map (name: "ENV ${name}=${builtins.toJSON (toString envVars.${name})}") names);

  renderContainerfile = {
    baseImage,
    aptPackages,
    installCommands,
    envVars,
    allowAllOutbound
  }:
    let
      resolvedPackages =
        sortUnique (
          aptPackages
          ++ lib.optional (!allowAllOutbound) "iptables"
          ++ lib.optional (!allowAllOutbound) "dnsutils"
        );
      installPackageBlock = ''
        RUN apt-get update && \
            apt-get install -y --no-install-recommends ${lib.concatStringsSep " " resolvedPackages} && \
            rm -rf /var/lib/apt/lists/*
      '';
      extraEnvBlock = renderEnvLines envVars;
    in lib.concatStringsSep "\n" (
      lib.filter (chunk: chunk != "") [
        "FROM ${baseImage}"
        "ENV DEBIAN_FRONTEND=noninteractive HOME=/root TERM=xterm-256color LANG=C.UTF-8"
        extraEnvBlock
        installPackageBlock
        (lib.optionalString (installCommands != "") installCommands)
        "RUN mkdir -p /workspace"
        "WORKDIR /workspace"
        "COPY entrypoint.sh /usr/local/bin/sandbox-entrypoint.sh"
        "RUN chmod +x /usr/local/bin/sandbox-entrypoint.sh"
        "ENTRYPOINT [\"/usr/local/bin/sandbox-entrypoint.sh\"]"
        ""
      ]
    );

  renderEntrypoint = {
    allowedDomains,
    allowDns,
    allowAllOutbound
  }:
    let
      renderedDomains = lib.concatStringsSep " " (map lib.escapeShellArg (sortUnique allowedDomains));
      dnsBlock = lib.optionalString allowDns ''
        iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
        iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT
      '';
    in
      if allowAllOutbound then
        ''
          #!/usr/bin/env bash
          set -euo pipefail

          exec "$@"
        ''
      else
        ''
          #!/usr/bin/env bash
          set -euo pipefail

          allowed_domains=(${renderedDomains})

          setup_network_filter() {
            if ! command -v iptables >/dev/null 2>&1; then
              echo "warning: iptables unavailable; outbound filter disabled" >&2
              return 0
            fi

            if ! iptables -L OUTPUT >/dev/null 2>&1; then
              echo "warning: iptables unsupported by kernel; outbound filter disabled" >&2
              return 0
            fi

            rollback_filter() {
              iptables -P OUTPUT ACCEPT >/dev/null 2>&1 || true
              iptables -F OUTPUT >/dev/null 2>&1 || true
            }

            trap rollback_filter ERR

            iptables -F OUTPUT
            iptables -A OUTPUT -o lo -j ACCEPT

            if ! iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null; then
              iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
            fi

          ${dnsBlock}

            for domain in "''${allowed_domains[@]}"; do
              while IFS= read -r ip; do
                case "$ip" in
                  ""|*[!0-9.]*)
                    continue
                    ;;
                esac
                iptables -A OUTPUT -d "$ip" -j ACCEPT
              done < <(dig +short "$domain" 2>/dev/null || true)
            done

            iptables -P OUTPUT DROP
            trap - ERR
          }

          setup_network_filter
          exec "$@"
        '';
in
{
  name,
  agentCommand ? null,
  aptPackages ? defaultAptPackages,
  baseImage ? "ubuntu:24.04",
  installCommands ? "",
  allowedDomains ? [ ],
  allowDns ? true,
  allowAllOutbound ? true,
  cpus ? 4,
  memory ? "8g",
  passEnv ? [ ],
  autoPassEnvByCommand ? { },
  envVars ? { },
  sshForward ? false,
  homeMounts ? [ ],
  extraVolumes ? [ ],
  publishPorts ? [ ],
  network ? null
}:
let
  normalizedAptPackages = sortUnique aptPackages;
  normalizedAllowedDomains = sortUnique allowedDomains;
  normalizedEnvVars = lib.mapAttrs (_: value: toString value) envVars;
  configHash = builtins.substring 0 12 (builtins.hashString "sha256" (builtins.toJSON {
    inherit baseImage installCommands normalizedAptPackages normalizedAllowedDomains normalizedEnvVars allowDns allowAllOutbound;
  }));
  containerfile = renderContainerfile {
    inherit baseImage installCommands allowAllOutbound;
    aptPackages = normalizedAptPackages;
    envVars = normalizedEnvVars;
  };
  entrypoint = renderEntrypoint {
    allowedDomains = normalizedAllowedDomains;
    inherit allowDns allowAllOutbound;
  };
  renderRuntimeArray = values: lib.concatStringsSep " " (map lib.escapeShellArg values);
  renderAutoForwardedEnvBlock = mappings:
    let
      commandNames = lib.sort builtins.lessThan (builtins.attrNames mappings);
      renderCase = commandName:
        let
          envNames = sortUnique mappings.${commandName};
        in ''
            ${lib.escapeShellArg commandName})
              auto_forwarded_envs=(${renderRuntimeArray envNames})
              ;;
        '';
    in
      if commandNames == [ ] then
        ''
          auto_forwarded_envs=()
        ''
      else
        ''
          auto_forwarded_envs=()
          case "$1" in
        ${lib.concatStringsSep "\n" (map renderCase commandNames)}
            *)
              ;;
          esac
        '';
  defaultForwardedEnvBlocks = renderRuntimeArray passEnv;
  defaultHomeMountBlocks = renderRuntimeArray homeMounts;
  defaultPublishPortBlocks = renderRuntimeArray publishPorts;
  defaultVolumeBlocks = renderRuntimeArray extraVolumes;
  autoForwardedEnvBlock = renderAutoForwardedEnvBlock autoPassEnvByCommand;
  commandDispatchBlock =
    if agentCommand == null then
      ''
        if ((''${#command_args[@]} > 0)); then
          run_args+=("''${command_args[@]}")
        else
          run_args+=("bash")
        fi
      ''
    else
      ''
        run_args+=(${lib.escapeShellArg agentCommand})

        if ((''${#command_args[@]} > 0)); then
          run_args+=("''${command_args[@]}")
        fi
      '';
in
pkgs.writeShellScriptBin name ''
  set -euo pipefail

  name=${lib.escapeShellArg name}
  image_tag=${lib.escapeShellArg "${name}:${configHash}"}
  cache_root="''${XDG_CACHE_HOME:-$HOME/.cache}/nix-apple-sandbox/$name"
  context_dir="$cache_root/build-context"
  marker_path="$cache_root/.built-${configHash}"
  default_forwarded_envs=(${defaultForwardedEnvBlocks})
  default_home_mounts=(${defaultHomeMountBlocks})
  default_publish_ports=(${defaultPublishPortBlocks})
  default_extra_volumes=(${defaultVolumeBlocks})
  runtime_forwarded_envs=()
  runtime_dropped_forwarded_envs=()
  runtime_home_mounts=()
  runtime_publish_ports=()
  runtime_extra_volumes=()
  runtime_direct_envs=()
  runtime_cpus=${lib.escapeShellArg (toString cpus)}
  runtime_memory=${lib.escapeShellArg memory}
  runtime_network=${lib.escapeShellArg (if network == null then "" else network)}
  runtime_ssh=${if sshForward then "1" else "0"}
  runtime_disable_auto_forwarded_envs=0
  fixed_agent_command=${lib.escapeShellArg (if agentCommand == null then "" else agentCommand)}
  command_args=()

  print_runtime_help() {
    cat <<EOF
usage: $name [runtime options] [--] [command args]

runtime options:
  --sandbox-cpus N          Override vCPU count for this run
  --sandbox-memory SIZE     Override memory for this run (example: 16g)
  --sandbox-pass-env NAME   Forward one host env var for this run
  --sandbox-drop-pass-env NAME
                            Remove one forwarded env var for this run
  --sandbox-no-auto-pass-env
                            Disable command-based automatic env forwarding
  --sandbox-env NAME=VALUE  Inject one env var directly for this run
  --sandbox-home-mount SPEC Mount a path from \$HOME (example: .claude or .agents:/root/.agents)
  --sandbox-volume SPEC     Add one raw volume mount (host:guest)
  --sandbox-publish SPEC    Add one published port (host:container)
  --sandbox-network NAME    Override container network for this run
  --sandbox-no-network      Clear any configured network for this run
  --sandbox-ssh             Enable SSH forwarding for this run
  --sandbox-no-ssh          Disable SSH forwarding for this run
  --sandbox-help            Show this help and exit

notes:
  - runtime options must come before '--' or before the command
  - build-time settings such as aptPackages, installCommands, and outbound filtering
    still come from the Nix configuration because they affect the image contents
EOF
  }

  require_option_value() {
    local flag=$1
    local argc=$2

    if ((argc < 2)); then
      echo "error: $flag requires a value" >&2
      exit 1
    fi
  }

  parse_runtime_options() {
    while (($# > 0)); do
      case "$1" in
        --sandbox-help)
          print_runtime_help
          exit 0
          ;;
        --sandbox-cpus)
          require_option_value "$1" "$#"
          runtime_cpus="$2"
          shift 2
          ;;
        --sandbox-memory)
          require_option_value "$1" "$#"
          runtime_memory="$2"
          shift 2
          ;;
        --sandbox-pass-env)
          require_option_value "$1" "$#"
          runtime_forwarded_envs+=("$2")
          shift 2
          ;;
        --sandbox-drop-pass-env)
          require_option_value "$1" "$#"
          runtime_dropped_forwarded_envs+=("$2")
          shift 2
          ;;
        --sandbox-no-auto-pass-env)
          runtime_disable_auto_forwarded_envs=1
          shift
          ;;
        --sandbox-env)
          require_option_value "$1" "$#"
          runtime_direct_envs+=("$2")
          shift 2
          ;;
        --sandbox-home-mount)
          require_option_value "$1" "$#"
          runtime_home_mounts+=("$2")
          shift 2
          ;;
        --sandbox-volume)
          require_option_value "$1" "$#"
          runtime_extra_volumes+=("$2")
          shift 2
          ;;
        --sandbox-publish)
          require_option_value "$1" "$#"
          runtime_publish_ports+=("$2")
          shift 2
          ;;
        --sandbox-network)
          require_option_value "$1" "$#"
          runtime_network="$2"
          shift 2
          ;;
        --sandbox-no-network)
          runtime_network=""
          shift
          ;;
        --sandbox-ssh)
          runtime_ssh=1
          shift
          ;;
        --sandbox-no-ssh)
          runtime_ssh=0
          shift
          ;;
        --)
          shift
          command_args=("$@")
          return 0
          ;;
        *)
          command_args=("$@")
          return 0
          ;;
      esac
    done
  }

  ensure_container_cli() {
    if ! command -v container >/dev/null 2>&1; then
      echo "error: Apple container CLI not found in PATH" >&2
      exit 1
    fi
  }

  ensure_container_system() {
    if ! container system status >/dev/null 2>&1; then
      echo "starting Apple Containers service..." >&2
      container system start --enable-kernel-install >/dev/null
    fi
  }

  ensure_image() {
    mkdir -p "$context_dir"

    if [[ -f "$marker_path" ]]; then
      return 0
    fi

    cat > "$context_dir/Containerfile" <<'EOF'
${containerfile}
EOF

    cat > "$context_dir/entrypoint.sh" <<'EOF'
${entrypoint}
EOF

    container build -t "$image_tag" "$context_dir"
    touch "$marker_path"
  }

  add_published_ports() {
    local port

    for port in "''${all_publish_ports[@]}"; do
      run_args+=(--publish "$port")
    done
  }

  add_extra_volumes() {
    local volume

    for volume in "''${all_extra_volumes[@]}"; do
      run_args+=(--volume "$volume")
    done
  }

  add_home_mounts() {
    local entry host_spec guest_path source_path relative_path

    for entry in "''${all_home_mounts[@]}"; do
      guest_path=""

      if [[ "$entry" == *:* ]]; then
        host_spec="''${entry%%:*}"
        guest_path="''${entry#*:}"
      else
        host_spec="$entry"
      fi

      if [[ "$host_spec" == "~/"* ]]; then
        relative_path="''${host_spec#~/}"
        source_path="$HOME/$relative_path"
      elif [[ "$host_spec" == /* ]]; then
        source_path="$host_spec"

        if [[ "$source_path" == "$HOME/"* ]]; then
          relative_path="''${source_path#$HOME/}"
        else
          relative_path="$(basename "$source_path")"
        fi
      else
        relative_path="''${host_spec#./}"
        source_path="$HOME/$relative_path"
      fi

      if [[ -z "$guest_path" ]]; then
        guest_path="/root/$relative_path"
      fi

      if [[ ! -e "$source_path" ]]; then
        echo "warning: home mount source not found: $source_path" >&2
        continue
      fi

      run_args+=(--volume "$source_path:$guest_path")
    done
  }

  determine_effective_command_name() {
    local command_name

    if [[ -n "$fixed_agent_command" ]]; then
      command_name="$fixed_agent_command"
    elif ((''${#command_args[@]} > 0)); then
      command_name="''${command_args[0]}"
    else
      command_name="bash"
    fi

    command_name="''${command_name##*/}"
    printf '%s\n' "$command_name"
  }

  resolve_auto_forwarded_envs() {
${autoForwardedEnvBlock}
  }

  merge_forwarded_envs() {
    local env_name seen existing

    for env_name in "$@"; do
      [[ -n "$env_name" ]] || continue

      existing=0
      for seen in "''${all_forwarded_envs[@]-}"; do
        if [[ "$seen" == "$env_name" ]]; then
          existing=1
          break
        fi
      done

      if (( ! existing )); then
        all_forwarded_envs+=("$env_name")
      fi
    done
  }

  drop_forwarded_envs() {
    local env_name removed_name should_drop
    local -a filtered_forwarded_envs=()

    for env_name in "''${all_forwarded_envs[@]-}"; do
      should_drop=0

      for removed_name in "''${runtime_dropped_forwarded_envs[@]-}"; do
        if [[ "$removed_name" == "$env_name" ]]; then
          should_drop=1
          break
        fi
      done

      if (( ! should_drop )); then
        filtered_forwarded_envs+=("$env_name")
      fi
    done

    all_forwarded_envs=("''${filtered_forwarded_envs[@]}")
  }

  add_forwarded_envs() {
    local env_name

    for env_name in "''${all_forwarded_envs[@]}"; do
      if [[ -n "''${!env_name-}" ]]; then
        run_args+=(--env "$env_name=''${!env_name}")
      fi
    done
  }

  add_direct_envs() {
    local entry

    for entry in "''${runtime_direct_envs[@]}"; do
      if [[ "$entry" != *=* ]]; then
        echo "error: --sandbox-env expects NAME=VALUE, got: $entry" >&2
        exit 1
      fi

      run_args+=(--env "$entry")
    done
  }

  main() {
    local workspace_dir
    local effective_command_name
    local -a run_args
    local -a auto_forwarded_envs
    local -a all_forwarded_envs
    local -a all_home_mounts
    local -a all_publish_ports
    local -a all_extra_volumes

    parse_runtime_options "$@"
    effective_command_name="$(determine_effective_command_name)"

    auto_forwarded_envs=()
    if (( ! runtime_disable_auto_forwarded_envs )); then
      resolve_auto_forwarded_envs "$effective_command_name"
    fi

    ensure_container_cli
    ensure_container_system
    ensure_image

    workspace_dir="$(pwd -P)"
    run_args=(run --rm -it --cpus "$runtime_cpus" --memory "$runtime_memory" --volume "$workspace_dir:/workspace")

    if [[ -n "$runtime_network" ]]; then
      run_args+=(--network "$runtime_network")
    fi

    if ((runtime_ssh)); then
      run_args+=(--ssh)
    fi

    all_publish_ports=("''${default_publish_ports[@]}" "''${runtime_publish_ports[@]}")
    all_extra_volumes=("''${default_extra_volumes[@]}" "''${runtime_extra_volumes[@]}")
    all_home_mounts=("''${default_home_mounts[@]}" "''${runtime_home_mounts[@]}")
    all_forwarded_envs=()
    merge_forwarded_envs "''${default_forwarded_envs[@]}"
    merge_forwarded_envs "''${auto_forwarded_envs[@]}"
    merge_forwarded_envs "''${runtime_forwarded_envs[@]}"
    drop_forwarded_envs

    add_published_ports
    add_extra_volumes

    add_home_mounts
    add_forwarded_envs
    add_direct_envs

    run_args+=("$image_tag")
${commandDispatchBlock}

    container "''${run_args[@]}"
  }

  main "$@"
''
