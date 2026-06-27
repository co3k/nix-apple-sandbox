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
    "util-linux"
  ];

  sandboxHome = "/home/sandbox";

  # Shell functions injected into the container entrypoint. They copy the
  # read-only staged host credentials (mounted at
  # $NIX_APPLE_SANDBOX_CREDENTIALS_DIR) into the throwaway in-container HOME.
  #
  # Safety properties:
  #   * Only files placed in the staging dir by the host wrapper are imported;
  #     the staging dir is a *copy*, never the real host files.
  #   * Ownership is fixed only on files we copy and directories we create, so
  #     we never recurse over a user-provided home mount that points at host
  #     files (which would let the agent tamper with host state).
  #   * Destinations backed by a host mount are skipped instead of written
  #     through to the host.
  credentialImportFunctions = ''
    import_dest_within_mount() {
      local dest=$1 dir
      dir=$(dirname "$dest")
      while :; do
        if [[ -d "$dir" ]] && mountpoint -q "$dir" 2>/dev/null; then
          return 0
        fi
        if [[ "$dir" == "$sandbox_home" || "$dir" == "/" ]]; then
          break
        fi
        dir=$(dirname "$dir")
      done
      if [[ -e "$dest" ]] && mountpoint -q "$dest" 2>/dev/null; then
        return 0
      fi
      return 1
    }

    create_credential_parents() {
      local leaf=$1 dir entry
      local -a pending=()
      dir=$leaf
      while [[ "$dir" != "$sandbox_home" && "$dir" != "/" ]]; do
        pending=("$dir" "''${pending[@]}")
        dir=$(dirname "$dir")
      done
      for entry in "''${pending[@]}"; do
        mkdir -p "$entry"
        chown "$sandbox_uid:$sandbox_gid" "$entry"
        chmod 700 "$entry"
      done
    }

    import_host_credentials() {
      local src_dir=''${NIX_APPLE_SANDBOX_CREDENTIALS_DIR:-}
      local rel dest

      [[ -n "$src_dir" && -d "$src_dir" ]] || return 0

      if ! command -v mountpoint >/dev/null 2>&1; then
        echo "warning: 'mountpoint' unavailable; skipping host credential import" >&2
        return 0
      fi

      while IFS= read -r -d "" rel; do
        rel=''${rel#"$src_dir"/}
        dest="$sandbox_home/$rel"

        if import_dest_within_mount "$dest"; then
          echo "warning: skipping imported credential '$rel'; destination is backed by a host mount" >&2
          continue
        fi

        create_credential_parents "$(dirname "$dest")"
        cp "$src_dir/$rel" "$dest"
        chown "$sandbox_uid:$sandbox_gid" "$dest"
        chmod 600 "$dest"
      done < <(find "$src_dir" -type f -print0)
    }
  '';

  sortUnique = values: lib.sort builtins.lessThan (lib.unique values);

  dedentGeneratedShell =
    text:
    lib.concatStringsSep "\n" (
      map (line: lib.removePrefix "          " line) (lib.splitString "\n" text)
    );

  renderEnvLines =
    envVars:
    let
      names = lib.sort builtins.lessThan (builtins.attrNames envVars);
    in
    lib.concatStringsSep "\n" (
      map (name: "ENV ${name}=${builtins.toJSON (toString envVars.${name})}") names
    );

  renderContainerfile =
    {
      baseImage,
      aptPackages,
      installCommands,
      envVars,
      allowAllOutbound,
    }:
    let
      resolvedPackages = sortUnique (
        aptPackages
        ++ [ "util-linux" ]
        ++ lib.optional (!allowAllOutbound) "iptables"
        ++ lib.optional (!allowAllOutbound) "dnsutils"
      );
      installPackageBlock = ''
        RUN apt-get update && \
            apt-get install -y --no-install-recommends ${lib.concatStringsSep " " resolvedPackages} && \
            rm -rf /var/lib/apt/lists/*
      '';
      extraEnvBlock = renderEnvLines envVars;
    in
    lib.concatStringsSep "\n" (
      lib.filter (chunk: chunk != "") [
        "FROM ${baseImage}"
        "ENV DEBIAN_FRONTEND=noninteractive HOME=/root TERM=xterm-256color LANG=C.UTF-8"
        extraEnvBlock
        installPackageBlock
        "RUN mkdir -p /workspace ${sandboxHome}"
        (lib.optionalString (installCommands != "") installCommands)
        "WORKDIR /workspace"
        "COPY entrypoint.sh /usr/local/bin/sandbox-entrypoint.sh"
        "RUN chmod +x /usr/local/bin/sandbox-entrypoint.sh"
        "ENTRYPOINT [\"/usr/local/bin/sandbox-entrypoint.sh\"]"
        ""
      ]
    );

  renderEntrypoint =
    {
      allowedDomains,
      allowDns,
      allowAllOutbound,
    }:
    let
      renderedDomains = lib.concatStringsSep " " (map lib.escapeShellArg (sortUnique allowedDomains));
      allowDnsFlag = if allowDns then "1" else "0";
    in
    if allowAllOutbound then
      ''
                  #!/usr/bin/env bash
                  set -euo pipefail

                  sandbox_home=${lib.escapeShellArg sandboxHome}
                  sandbox_uid="''${NIX_APPLE_SANDBOX_UID:-1000}"
                  sandbox_gid="''${NIX_APPLE_SANDBOX_GID:-1000}"
                  sandbox_user="''${NIX_APPLE_SANDBOX_USER:-sandbox}"

        ${credentialImportFunctions}

                  mkdir -p "$sandbox_home"
                  chown "$sandbox_uid:$sandbox_gid" "$sandbox_home"
                  import_host_credentials
                  cd /workspace

                  exec env HOME="$sandbox_home" USER="$sandbox_user" LOGNAME="$sandbox_user" \
                    setpriv --reuid "$sandbox_uid" --regid "$sandbox_gid" --clear-groups "$@"
      ''
    else
      ''
                  #!/usr/bin/env bash
                  set -euo pipefail

                  allowed_domains=(${renderedDomains})
                  sandbox_home=${lib.escapeShellArg sandboxHome}
                  sandbox_uid="''${NIX_APPLE_SANDBOX_UID:-1000}"
                  sandbox_gid="''${NIX_APPLE_SANDBOX_GID:-1000}"
                  sandbox_user="''${NIX_APPLE_SANDBOX_USER:-sandbox}"

        ${credentialImportFunctions}

                  exec_as_sandbox() {
                    mkdir -p "$sandbox_home"
                    chown "$sandbox_uid:$sandbox_gid" "$sandbox_home"
                    import_host_credentials
                    cd /workspace

                    exec env HOME="$sandbox_home" USER="$sandbox_user" LOGNAME="$sandbox_user" \
                      setpriv --reuid "$sandbox_uid" --regid "$sandbox_gid" --clear-groups "$@"
                  }

                  setup_network_filter() {
                    local allow_dns=${allowDnsFlag}
                    local ipv6_filter_available=0
                    local -a dns_resolvers_v4=()
                    local -a dns_resolvers_v6=()
                    local -a resolved_ipv4=()
                    local -a resolved_ipv6=()
                    local -a resolved_host_ips=()
                    local -a resolved_host_names=()

                    if ! command -v iptables >/dev/null 2>&1; then
                      echo "error: iptables unavailable; refusing to start without outbound filter" >&2
                      exit 1
                    fi

                    if ! iptables -L OUTPUT >/dev/null 2>&1; then
                      echo "error: iptables unsupported by kernel; refusing to start without outbound filter" >&2
                      exit 1
                    fi

                    if command -v ip6tables >/dev/null 2>&1 && ip6tables -L OUTPUT >/dev/null 2>&1; then
                      ipv6_filter_available=1
                    elif ipv6_network_available; then
                      echo "error: ip6tables unavailable or unsupported while IPv6 networking is enabled; refusing to start without IPv6 outbound filter" >&2
                      exit 1
                    fi

                    rollback_filter() {
                      iptables -P OUTPUT ACCEPT >/dev/null 2>&1 || true
                      iptables -F OUTPUT >/dev/null 2>&1 || true
                      if ((ipv6_filter_available)); then
                        ip6tables -P OUTPUT ACCEPT >/dev/null 2>&1 || true
                        ip6tables -F OUTPUT >/dev/null 2>&1 || true
                      fi
                    }

                    trap rollback_filter ERR

                    iptables -P OUTPUT DROP
                    if ((ipv6_filter_available)); then
                      ip6tables -P OUTPUT DROP
                    fi

                    read_dns_resolvers

                    add_base_ipv4_rules
                    add_base_ipv6_rules
                    add_temporary_dns_rules
                    resolve_allowed_domains
                    write_allowed_domain_hosts

                    add_base_ipv4_rules
                    add_base_ipv6_rules
                    add_allowed_domain_rules
                    trap - ERR
                  }

                  ipv6_network_available() {
                    local iface

                    [[ -r /proc/net/if_inet6 ]] || return 1

                    while read -r _ _ _ _ _ iface; do
                      if [[ -n "$iface" && "$iface" != "lo" ]]; then
                        return 0
                      fi
                    done < /proc/net/if_inet6

                    return 1
                  }

                  read_dns_resolvers() {
                    local keyword resolver

                    [[ -r /etc/resolv.conf ]] || return 0

                    while read -r keyword resolver _; do
                      [[ "$keyword" == "nameserver" ]] || continue

                      case "$resolver" in
                        *:*)
                          case "$resolver" in
                            *[!0-9A-Fa-f:.%]*)
                              continue
                              ;;
                          esac
                          resolver="''${resolver%%%*}"
                          dns_resolvers_v6+=("$resolver")
                          ;;
                        *.*)
                          case "$resolver" in
                            *[!0-9.]*)
                              continue
                              ;;
                          esac
                          dns_resolvers_v4+=("$resolver")
                          ;;
                      esac
                    done < /etc/resolv.conf
                  }

                  add_base_ipv4_rules() {
                    iptables -F OUTPUT
                    iptables -A OUTPUT -o lo -j ACCEPT

                    if ! iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null; then
                      iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
                    fi
                  }

                  add_base_ipv6_rules() {
                    ((ipv6_filter_available)) || return 0

                    ip6tables -F OUTPUT
                    ip6tables -A OUTPUT -o lo -j ACCEPT

                    if ! ip6tables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null; then
                      ip6tables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
                    fi
                  }

                  add_temporary_dns_rules() {
                    local resolver

                    ((allow_dns)) || return 0
                    ((''${#allowed_domains[@]} > 0)) || return 0

                    if ((''${#dns_resolvers_v4[@]} == 0 && ''${#dns_resolvers_v6[@]} == 0)); then
                      echo "error: no nameserver entries found in /etc/resolv.conf; cannot resolve allowedDomains" >&2
                      return 1
                    fi

                    for resolver in "''${dns_resolvers_v4[@]}"; do
                      iptables -A OUTPUT -p udp -d "$resolver" --dport 53 -j ACCEPT
                      iptables -A OUTPUT -p tcp -d "$resolver" --dport 53 -j ACCEPT
                    done

                    if ((ipv6_filter_available)); then
                      for resolver in "''${dns_resolvers_v6[@]}"; do
                        ip6tables -A OUTPUT -p udp -d "$resolver" --dport 53 -j ACCEPT
                        ip6tables -A OUTPUT -p tcp -d "$resolver" --dport 53 -j ACCEPT
                      done
                    fi
                  }

                  resolve_allowed_domains() {
                    local domain ip

                    if (( ! allow_dns )); then
                      if ((''${#allowed_domains[@]} > 0)); then
                        echo "warning: allowDns=false; skipping allowedDomains DNS resolution" >&2
                      fi
                      return 0
                    fi

                    for domain in "''${allowed_domains[@]}"; do
                      while IFS= read -r ip; do
                        case "$ip" in
                          ""|*[!0-9.]*)
                            continue
                            ;;
                        esac
                        resolved_ipv4+=("$ip")
                        resolved_host_ips+=("$ip")
                        resolved_host_names+=("$domain")
                      done < <(dig +short A "$domain" 2>/dev/null || true)

                      if ((ipv6_filter_available)); then
                        while IFS= read -r ip; do
                          case "$ip" in
                            *:*)
                              case "$ip" in
                                *[!0-9A-Fa-f:.]*)
                                  continue
                                  ;;
                              esac
                              resolved_ipv6+=("$ip")
                              resolved_host_ips+=("$ip")
                              resolved_host_names+=("$domain")
                              ;;
                          esac
                        done < <(dig +short AAAA "$domain" 2>/dev/null || true)
                      fi
                    done
                  }

                  write_allowed_domain_hosts() {
                    local idx

                    ((''${#resolved_host_ips[@]} > 0)) || return 0

                    {
                      printf '\n# nix-apple-sandbox allowedDomains resolved at startup\n'
                      for idx in "''${!resolved_host_ips[@]}"; do
                        printf '%s %s\n' "''${resolved_host_ips[$idx]}" "''${resolved_host_names[$idx]}"
                      done
                    } >> /etc/hosts
                  }

                  add_allowed_domain_rules() {
                    local ip

                    for ip in "''${resolved_ipv4[@]}"; do
                      iptables -A OUTPUT -d "$ip" -j ACCEPT
                    done

                    if ((ipv6_filter_available)); then
                      for ip in "''${resolved_ipv6[@]}"; do
                        ip6tables -A OUTPUT -d "$ip" -j ACCEPT
                      done
                    fi
                  }

                  setup_network_filter
                  exec_as_sandbox "$@"
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
  network ? null,
  hostCredentialImports ? [ ],
  autoHostCredentialImportsByCommand ? { },
}:
let
  normalizedAptPackages = sortUnique aptPackages;
  normalizedAllowedDomains = sortUnique allowedDomains;
  normalizedEnvVars = lib.mapAttrs (_: value: toString value) envVars;
  containerfile = renderContainerfile {
    inherit baseImage installCommands allowAllOutbound;
    aptPackages = normalizedAptPackages;
    envVars = normalizedEnvVars;
  };
  entrypoint = dedentGeneratedShell (renderEntrypoint {
    allowedDomains = normalizedAllowedDomains;
    inherit allowDns allowAllOutbound;
  });
  configHash = builtins.substring 0 12 (
    builtins.hashString "sha256" (
      builtins.toJSON {
        inherit containerfile entrypoint;
      }
    )
  );
  renderRuntimeArray = values: lib.concatStringsSep " " (map lib.escapeShellArg values);
  normalizeHostCredentialImport =
    credential:
    let
      kind = credential.kind or "file";
      target = credential.target;
    in
    {
      inherit kind target;
      name = credential.name or target;
      source = credential.source or "";
      keychainService = credential.keychainService or (credential.service or "");
      keychainAccount = credential.keychainAccount or (credential.account or "");
      jqFilter = credential.jqFilter or "";
    };
  renderHostCredentialAppendBlock =
    credentials:
    let
      normalized = map normalizeHostCredentialImport credentials;
      renderOne = credential: ''
        append_host_credential_import \
          ${lib.escapeShellArg credential.kind} \
          ${lib.escapeShellArg credential.source} \
          ${lib.escapeShellArg credential.target} \
          ${lib.escapeShellArg credential.keychainService} \
          ${lib.escapeShellArg credential.keychainAccount} \
          ${lib.escapeShellArg credential.jqFilter} \
          ${lib.escapeShellArg credential.name}
      '';
    in
    lib.concatStringsSep "\n" (map renderOne normalized);
  renderAutoForwardedEnvBlock =
    mappings:
    let
      commandNames = lib.sort builtins.lessThan (builtins.attrNames mappings);
      renderCase =
        commandName:
        let
          envNames = sortUnique mappings.${commandName};
        in
        ''
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
  renderAutoHostCredentialImportBlock =
    mappings:
    let
      commandNames = lib.sort builtins.lessThan (builtins.attrNames mappings);
      renderCase = commandName: ''
                  ${lib.escapeShellArg commandName})
        ${renderHostCredentialAppendBlock mappings.${commandName}}
                    ;;
      '';
    in
    if commandNames == [ ] then
      ''
        :
      ''
    else
      ''
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
  defaultHostCredentialImportBlock =
    let
      block = renderHostCredentialAppendBlock hostCredentialImports;
    in
    if block == "" then "    :" else block;
  autoHostCredentialImportBlock = renderAutoHostCredentialImportBlock autoHostCredentialImportsByCommand;
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
    runtime_host_credential_specs=()
    runtime_cpus=${lib.escapeShellArg (toString cpus)}
    runtime_memory=${lib.escapeShellArg memory}
    runtime_network=${lib.escapeShellArg (if network == null then "" else network)}
    runtime_ssh=${if sshForward then "1" else "0"}
    runtime_disable_auto_forwarded_envs=0
    runtime_disable_host_credentials=0
    credential_stage_dir=""
    fixed_agent_command=${lib.escapeShellArg (if agentCommand == null then "" else agentCommand)}
    container_cli=""
    minimum_container_version="0.10.0"
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
    --sandbox-no-host-credentials
                              Disable host credential staging for this run
    --sandbox-host-credential SPEC
                              Stage one host credential file copy (example: .codex/auth.json:.codex/auth.json)
    --sandbox-home-mount SPEC Mount a path from \$HOME (example: .claude or .agents:${sandboxHome}/.agents)
    --sandbox-volume SPEC     Add one raw volume mount (host:guest)
    --sandbox-publish SPEC    Add one published port (host:container)
    --sandbox-network NAME    Override container network for this run
    --sandbox-no-network      Clear any configured network for this run
    --sandbox-ssh             Enable SSH forwarding for this run
    --sandbox-no-ssh          Disable SSH forwarding for this run
    --sandbox-help            Show this help and exit

  notes:
    - runtime options must come before '--' or before the command
    - host credentials are copied into a temporary directory, mounted read-only,
      then copied into the container's throwaway HOME; real host credential files
      are never mounted into the container
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
          --sandbox-no-host-credentials)
            runtime_disable_host_credentials=1
            shift
            ;;
          --sandbox-host-credential)
            require_option_value "$1" "$#"
            runtime_host_credential_specs+=("$2")
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

    version_gte() {
      local lhs=$1
      local rhs=$2
      local idx lhs_part rhs_part
      local -a lhs_parts=()
      local -a rhs_parts=()

      IFS=. read -r -a lhs_parts <<<"$lhs"
      IFS=. read -r -a rhs_parts <<<"$rhs"

      for idx in 0 1 2; do
        lhs_part="''${lhs_parts[$idx]:-0}"
        rhs_part="''${rhs_parts[$idx]:-0}"
        lhs_part="''${lhs_part%%[^0-9]*}"
        rhs_part="''${rhs_part%%[^0-9]*}"
        lhs_part="''${lhs_part:-0}"
        rhs_part="''${rhs_part:-0}"

        if ((10#$lhs_part > 10#$rhs_part)); then
          return 0
        fi

        if ((10#$lhs_part < 10#$rhs_part)); then
          return 1
        fi
      done

      return 0
    }

    ensure_container_cli() {
      local detected_cli detected_version formula_cli formula_version

      formula_cli="/opt/homebrew/opt/container/bin/container"
      detected_cli="$(command -v container || true)"
      detected_version=""

      if [[ -n "$detected_cli" ]]; then
        detected_version="$("$detected_cli" --version 2>/dev/null | awk '/container CLI version/ { print $4; exit }')"
        if [[ -n "$detected_version" ]] && version_gte "$detected_version" "$minimum_container_version"; then
          container_cli="$detected_cli"
          return 0
        fi
      fi

      formula_version=""
      if [[ -x "$formula_cli" ]]; then
        formula_version="$("$formula_cli" --version 2>/dev/null | awk '/container CLI version/ { print $4; exit }')"
        if [[ -n "$formula_version" ]] && version_gte "$formula_version" "$minimum_container_version"; then
          container_cli="$formula_cli"
          if [[ -n "$detected_cli" ]] && [[ "$detected_cli" != "$formula_cli" ]]; then
            echo "warning: ignoring outdated container CLI at $detected_cli (found ''${detected_version:-unknown}); using $formula_cli (''${formula_version})" >&2
          fi
          return 0
        fi
      fi

      if [[ -n "$detected_cli" ]]; then
        echo "error: container CLI at $detected_cli is too old (found ''${detected_version:-unknown}; need >= $minimum_container_version)" >&2
        echo "hint: remove the legacy Homebrew cask or update PATH to prefer /opt/homebrew/opt/container/bin/container" >&2
        exit 1
      fi

      echo "error: Apple container CLI not found in PATH" >&2
      exit 1
    }

    ensure_container_system() {
      if ! "$container_cli" system status >/dev/null 2>&1; then
        echo "starting Apple Containers service..." >&2
        "$container_cli" system start --enable-kernel-install >/dev/null
      fi
    }

    ensure_image() {
      mkdir -p "$context_dir"

      if [[ -f "$marker_path" ]]; then
        return 0
      fi

      printf '%s\n' ${lib.escapeShellArg containerfile} > "$context_dir/Containerfile"
      printf '%s\n' ${lib.escapeShellArg entrypoint} > "$context_dir/entrypoint.sh"

      "$container_cli" build -t "$image_tag" "$context_dir"
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
          guest_path="${sandboxHome}/$relative_path"
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

    append_host_credential_import() {
      all_host_credential_kinds+=("$1")
      all_host_credential_sources+=("$2")
      all_host_credential_targets+=("$3")
      all_host_credential_keychain_services+=("$4")
      all_host_credential_keychain_accounts+=("$5")
      all_host_credential_jq_filters+=("$6")
      all_host_credential_names+=("$7")
    }

    add_default_host_credential_imports() {
  ${defaultHostCredentialImportBlock}
    }

    resolve_auto_host_credential_imports() {
  ${autoHostCredentialImportBlock}
    }

    resolve_host_path() {
      local spec=$1

      if [[ "$spec" == "~/"* ]]; then
        printf '%s/%s\n' "$HOME" "''${spec#~/}"
      elif [[ "$spec" == /* ]]; then
        printf '%s\n' "$spec"
      else
        printf '%s/%s\n' "$HOME" "''${spec#./}"
      fi
    }

    append_runtime_host_credential_import() {
      local spec=$1 source_spec target source_path

      if [[ "$spec" == *:* ]]; then
        source_spec="''${spec%%:*}"
        target="''${spec#*:}"
      else
        source_spec="$spec"
        source_path="$(resolve_host_path "$source_spec")"

        if [[ "$source_path" == "$HOME/"* ]]; then
          target="''${source_path#$HOME/}"
        else
          target="$(basename "$source_path")"
        fi
      fi

      append_host_credential_import "file" "$source_spec" "$target" "" "" "" "runtime:$source_spec"
    }

    normalize_credential_target() {
      local target=$1

      target="''${target#./}"
      case "$target" in
        ""|"."|".."|/*|../*|*/../*|*/..)
          echo "error: unsafe host credential target: $1" >&2
          exit 1
          ;;
      esac

      printf '%s\n' "$target"
    }

    prepare_credential_destination() {
      local target=$1 dest_path parent_dir

      target="$(normalize_credential_target "$target")"
      dest_path="$credential_stage_dir/$target"
      parent_dir="$(dirname "$dest_path")"
      mkdir -p "$parent_dir"
      printf '%s\n' "$dest_path"
    }

    copy_file_host_credential() {
      local source_spec=$1 target=$2 name=$3
      local source_path dest_path

      if [[ -z "$source_spec" ]]; then
        echo "warning: host credential '$name' has no source; skipping" >&2
        return 0
      fi

      source_path="$(resolve_host_path "$source_spec")"
      if [[ ! -e "$source_path" ]]; then
        echo "warning: host credential source not found: $source_path" >&2
        return 0
      fi

      if [[ -L "$source_path" || ! -f "$source_path" ]]; then
        echo "warning: host credential source is not a regular file: $source_path" >&2
        return 0
      fi

      dest_path="$(prepare_credential_destination "$target")"
      cp "$source_path" "$dest_path"
      chmod 600 "$dest_path"
    }

    copy_keychain_host_credential() {
      local service=$1 account=$2 jq_filter=$3 target=$4 name=$5
      local dest_path tmp_path
      local -a security_args

      if [[ -z "$service" ]]; then
        echo "warning: keychain host credential '$name' has no service; skipping" >&2
        return 0
      fi

      if [[ ! -x /usr/bin/security ]]; then
        echo "warning: /usr/bin/security unavailable; skipping keychain host credential '$name'" >&2
        return 0
      fi

      dest_path="$(prepare_credential_destination "$target")"
      tmp_path="$dest_path.tmp"
      rm -f "$tmp_path"

      security_args=(find-generic-password -s "$service" -w)
      if [[ -n "$account" ]]; then
        security_args+=( -a "$account" )
      fi

      if [[ -n "$jq_filter" ]]; then
        if ! /usr/bin/security "''${security_args[@]}" 2>/dev/null | ${pkgs.jq}/bin/jq -c "$jq_filter" > "$tmp_path"; then
          rm -f "$tmp_path"
          echo "warning: failed to read/filter keychain host credential '$name'; skipping" >&2
          return 0
        fi
      else
        if ! /usr/bin/security "''${security_args[@]}" > "$tmp_path" 2>/dev/null; then
          rm -f "$tmp_path"
          echo "warning: failed to read keychain host credential '$name'; skipping" >&2
          return 0
        fi
      fi

      mv "$tmp_path" "$dest_path"
      chmod 600 "$dest_path"
    }

    cleanup_staged_credentials() {
      if [[ -n "$credential_stage_dir" && -d "$credential_stage_dir" ]]; then
        rm -rf "$credential_stage_dir"
      fi
    }

    stage_host_credentials() {
      local idx kind source target service account jq_filter name staged_file

      ((runtime_disable_host_credentials)) && return 0
      ((''${#all_host_credential_kinds[@]} > 0)) || return 0

      credential_stage_dir="$(mktemp -d "''${TMPDIR:-/tmp}/nix-apple-sandbox-credentials.XXXXXXXXXX")"
      chmod 700 "$credential_stage_dir"
      trap cleanup_staged_credentials EXIT

      for idx in "''${!all_host_credential_kinds[@]}"; do
        kind="''${all_host_credential_kinds[$idx]}"
        source="''${all_host_credential_sources[$idx]}"
        target="''${all_host_credential_targets[$idx]}"
        service="''${all_host_credential_keychain_services[$idx]}"
        account="''${all_host_credential_keychain_accounts[$idx]}"
        jq_filter="''${all_host_credential_jq_filters[$idx]}"
        name="''${all_host_credential_names[$idx]}"

        case "$kind" in
          file)
            copy_file_host_credential "$source" "$target" "$name"
            ;;
          keychain-generic-password)
            copy_keychain_host_credential "$service" "$account" "$jq_filter" "$target" "$name"
            ;;
          *)
            echo "warning: unknown host credential kind '$kind' for '$name'; skipping" >&2
            ;;
        esac
      done

      staged_file="$(find "$credential_stage_dir" -type f -print -quit)"
      if [[ -z "$staged_file" ]]; then
        cleanup_staged_credentials
        credential_stage_dir=""
        return 0
      fi

      run_args+=(--mount "type=bind,source=$credential_stage_dir,target=/run/host-credentials,readonly")
      run_args+=(--env "NIX_APPLE_SANDBOX_CREDENTIALS_DIR=/run/host-credentials")
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
      local -a all_host_credential_kinds
      local -a all_host_credential_sources
      local -a all_host_credential_targets
      local -a all_host_credential_keychain_services
      local -a all_host_credential_keychain_accounts
      local -a all_host_credential_jq_filters
      local -a all_host_credential_names

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
      run_args+=(--env "NIX_APPLE_SANDBOX_UID=$(id -u)")
      run_args+=(--env "NIX_APPLE_SANDBOX_GID=$(id -g)")
      run_args+=(--env "NIX_APPLE_SANDBOX_USER=''${USER:-sandbox}")

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

      all_host_credential_kinds=()
      all_host_credential_sources=()
      all_host_credential_targets=()
      all_host_credential_keychain_services=()
      all_host_credential_keychain_accounts=()
      all_host_credential_jq_filters=()
      all_host_credential_names=()
      if (( ! runtime_disable_host_credentials )); then
        add_default_host_credential_imports
        resolve_auto_host_credential_imports "$effective_command_name"
        for host_credential_spec in "''${runtime_host_credential_specs[@]}"; do
          append_runtime_host_credential_import "$host_credential_spec"
        done
      fi

      add_published_ports
      add_extra_volumes

      add_home_mounts
      stage_host_credentials
      add_forwarded_envs
      add_direct_envs

      run_args+=("$image_tag")
  ${commandDispatchBlock}

      "$container_cli" "''${run_args[@]}"
    }

    main "$@"
''
