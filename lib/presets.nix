{ pkgs }:
let
  lib = pkgs.lib;
  mkSandboxedAgent = import ./mkSandboxedAgent.nix { inherit pkgs; };

  commonAptPackages = [
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

  defaultAllowedDomains = [
    "github.com"
    "api.github.com"
    "api.anthropic.com"
    "statsig.anthropic.com"
    "sentry.io"
    "registry.npmjs.org"
    "pypi.org"
    "files.pythonhosted.org"
  ];

  joinInstallCommands = commands:
    lib.concatStringsSep "\n" (lib.filter (command: command != "") commands);

  mkSandboxedCommand = {
    name ? "nix-apple-sandbox",
    extraAptPackages ? [ ],
    extraAllowedDomains ? [ ],
    installCommands ? "",
    passEnv ? [ ],
    autoPassEnvByCommand ? { },
    envVars ? { },
    cpus ? 4,
    memory ? "8g",
    allowAllOutbound ? false,
    allowDns ? true,
    sshForward ? false,
    homeMounts ? [ ],
    publishPorts ? [ ],
    extraVolumes ? [ ],
    network ? null,
    baseImage ? "ubuntu:24.04"
  }:
    mkSandboxedAgent {
      inherit
        name
        baseImage
        installCommands
        cpus
        memory
        allowAllOutbound
        allowDns
        passEnv
        autoPassEnvByCommand
        envVars
        sshForward
        homeMounts
        publishPorts
        extraVolumes
        network;
      aptPackages = commonAptPackages ++ extraAptPackages;
      allowedDomains = defaultAllowedDomains ++ extraAllowedDomains;
    };

  mkNodeAgent = {
    name,
    agentCommand,
    npmPackage,
    passEnv,
    baseAllowedDomains,
    extraAptPackages ? [ ],
    extraAllowedDomains ? [ ],
    cpus ? 4,
    memory ? "8g",
    allowAllOutbound ? false,
    allowDns ? true,
    sshForward ? false,
    homeMounts ? [ ],
    publishPorts ? [ ],
    extraVolumes ? [ ],
    network ? null,
    envVars ? { },
    baseImage ? "ubuntu:24.04"
  }:
    mkSandboxedAgent {
      inherit
        name
        agentCommand
        baseImage
        cpus
        memory
        allowAllOutbound
        allowDns
        passEnv
        envVars
        sshForward
        homeMounts
        publishPorts
        extraVolumes
        network;
      aptPackages = commonAptPackages ++ [ "nodejs" "npm" ] ++ extraAptPackages;
      allowedDomains = baseAllowedDomains ++ extraAllowedDomains;
      installCommands = joinInstallCommands [
        "RUN npm install -g ${npmPackage}"
      ];
    };
in {
  inherit mkSandboxedAgent commonAptPackages defaultAllowedDomains;
  inherit mkSandboxedCommand;

  mkSandboxedClaudeCode = {
    extraAptPackages ? [ ],
    extraAllowedDomains ? [ ],
    cpus ? 4,
    memory ? "8g",
    allowAllOutbound ? false,
    sshForward ? false,
    homeMounts ? [ ],
    publishPorts ? [ ],
    extraVolumes ? [ ],
    network ? null
  }:
    mkNodeAgent {
      name = "sandboxed-claude-code";
      agentCommand = "claude";
      npmPackage = "@anthropic-ai/claude-code";
      passEnv = [ "ANTHROPIC_API_KEY" ];
      baseAllowedDomains = defaultAllowedDomains;
      inherit
        extraAptPackages
        extraAllowedDomains
        cpus
        memory
        allowAllOutbound
        sshForward
        homeMounts
        publishPorts
        extraVolumes
        network;
    };

  mkSandboxedCodex = {
    extraAptPackages ? [ ],
    extraAllowedDomains ? [ ],
    cpus ? 4,
    memory ? "8g",
    allowAllOutbound ? false,
    sshForward ? false,
    homeMounts ? [ ],
    publishPorts ? [ ],
    extraVolumes ? [ ],
    network ? null
  }:
    mkNodeAgent {
      name = "sandboxed-codex";
      agentCommand = "codex";
      npmPackage = "@openai/codex";
      passEnv = [ "OPENAI_API_KEY" ];
      baseAllowedDomains = defaultAllowedDomains ++ [ "api.openai.com" ];
      inherit
        extraAptPackages
        extraAllowedDomains
        cpus
        memory
        allowAllOutbound
        sshForward
        homeMounts
        publishPorts
        extraVolumes
        network;
    };

  mkSandboxedGemini = {
    extraAptPackages ? [ ],
    extraAllowedDomains ? [ ],
    cpus ? 4,
    memory ? "8g",
    allowAllOutbound ? false,
    sshForward ? false,
    homeMounts ? [ ],
    publishPorts ? [ ],
    extraVolumes ? [ ],
    network ? null
  }:
    mkNodeAgent {
      name = "sandboxed-gemini";
      agentCommand = "gemini";
      npmPackage = "@google/gemini-cli";
      passEnv = [ "GEMINI_API_KEY" "GOOGLE_API_KEY" ];
      baseAllowedDomains = defaultAllowedDomains ++ [ "generativelanguage.googleapis.com" ];
      inherit
        extraAptPackages
        extraAllowedDomains
        cpus
        memory
        allowAllOutbound
        sshForward
        homeMounts
        publishPorts
        extraVolumes
        network;
    };

  mkSandboxedShell = {
    extraAptPackages ? [ ],
    cpus ? 4,
    memory ? "8g",
    homeMounts ? [ ],
    publishPorts ? [ ],
    extraVolumes ? [ ],
    network ? null
  }:
    mkSandboxedAgent {
      name = "sandboxed-shell";
      agentCommand = "bash";
      aptPackages = commonAptPackages ++ extraAptPackages;
      allowAllOutbound = true;
      inherit cpus memory homeMounts publishPorts extraVolumes network;
    };
}
