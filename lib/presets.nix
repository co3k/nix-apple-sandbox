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

  defaultHostCredentialImports = {
    codexAuth = {
      name = "codex-auth";
      kind = "file";
      source = ".codex/auth.json";
      target = ".codex/auth.json";
    };

    claudeCodeOAuth = {
      name = "claude-code-oauth";
      kind = "keychain-generic-password";
      keychainService = "Claude Code-credentials";
      target = ".claude/.credentials.json";
      # Claude Code stores several credential groups in this Keychain item on
      # macOS. Only stage the first-party Claude OAuth payload by default, not
      # MCP provider OAuth tokens that may also be present.
      jqFilter = "{claudeAiOauth}";
    };

    geminiOAuth = {
      name = "gemini-oauth";
      kind = "file";
      source = ".gemini/oauth_creds.json";
      target = ".gemini/oauth_creds.json";
    };
  };

  defaultAutoHostCredentialImportsByCommand = {
    claude = [ defaultHostCredentialImports.claudeCodeOAuth ];
    codex = [ defaultHostCredentialImports.codexAuth ];
    gemini = [ defaultHostCredentialImports.geminiOAuth ];
  };

  defaultHostCredentialImportAliases = defaultAutoHostCredentialImportsByCommand;

  joinInstallCommands =
    commands: lib.concatStringsSep "\n" (lib.filter (command: command != "") commands);

  mkSandboxedCommand =
    {
      name ? "nix-apple-sandbox",
      extraAptPackages ? [ ],
      extraAllowedDomains ? [ ],
      installCommands ? "",
      passEnv ? [ ],
      autoPassEnvByCommand ? { },
      hostCredentialImports ? [ ],
      autoHostCredentialImportsByCommand ? { },
      hostCredentialImportAliases ? defaultHostCredentialImportAliases,
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
      baseImage ? "ubuntu:24.04",
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
        hostCredentialImports
        autoHostCredentialImportsByCommand
        hostCredentialImportAliases
        envVars
        sshForward
        homeMounts
        publishPorts
        extraVolumes
        network
        ;
      aptPackages = commonAptPackages ++ extraAptPackages;
      allowedDomains = defaultAllowedDomains ++ extraAllowedDomains;
    };

  mkNodeAgent =
    {
      name,
      agentCommand,
      npmPackage,
      passEnv,
      baseAllowedDomains,
      hostCredentialImports ? [ ],
      autoHostCredentialImportsByCommand ? { },
      hostCredentialImportAliases ? defaultHostCredentialImportAliases,
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
      baseImage ? "ubuntu:24.04",
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
        hostCredentialImports
        autoHostCredentialImportsByCommand
        hostCredentialImportAliases
        envVars
        sshForward
        homeMounts
        publishPorts
        extraVolumes
        network
        ;
      aptPackages =
        commonAptPackages
        ++ [
          "nodejs"
          "npm"
        ]
        ++ extraAptPackages;
      allowedDomains = baseAllowedDomains ++ extraAllowedDomains;
      installCommands = joinInstallCommands [
        "RUN npm install -g ${npmPackage}"
      ];
    };
in
{
  inherit mkSandboxedAgent commonAptPackages defaultAllowedDomains;
  inherit
    defaultHostCredentialImports
    defaultAutoHostCredentialImportsByCommand
    defaultHostCredentialImportAliases
    ;
  inherit mkSandboxedCommand;

  mkSandboxedClaudeCode =
    {
      extraAptPackages ? [ ],
      extraAllowedDomains ? [ ],
      cpus ? 4,
      memory ? "8g",
      allowAllOutbound ? false,
      importHostCredentials ? true,
      hostCredentialImports ? lib.optional importHostCredentials defaultHostCredentialImports.claudeCodeOAuth,
      sshForward ? false,
      homeMounts ? [ ],
      publishPorts ? [ ],
      extraVolumes ? [ ],
      network ? null,
    }:
    mkNodeAgent {
      name = "sandboxed-claude-code";
      agentCommand = "claude";
      npmPackage = "@anthropic-ai/claude-code";
      passEnv = [ "ANTHROPIC_API_KEY" ];
      baseAllowedDomains = defaultAllowedDomains;
      inherit hostCredentialImports;
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
        network
        ;
    };

  mkSandboxedCodex =
    {
      extraAptPackages ? [ ],
      extraAllowedDomains ? [ ],
      cpus ? 4,
      memory ? "8g",
      allowAllOutbound ? false,
      importHostCredentials ? true,
      hostCredentialImports ? lib.optional importHostCredentials defaultHostCredentialImports.codexAuth,
      sshForward ? false,
      homeMounts ? [ ],
      publishPorts ? [ ],
      extraVolumes ? [ ],
      network ? null,
    }:
    mkNodeAgent {
      name = "sandboxed-codex";
      agentCommand = "codex";
      npmPackage = "@openai/codex";
      passEnv = [ "OPENAI_API_KEY" ];
      baseAllowedDomains = defaultAllowedDomains ++ [ "api.openai.com" ];
      inherit hostCredentialImports;
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
        network
        ;
    };

  mkSandboxedGemini =
    {
      extraAptPackages ? [ ],
      extraAllowedDomains ? [ ],
      cpus ? 4,
      memory ? "8g",
      allowAllOutbound ? false,
      importHostCredentials ? true,
      hostCredentialImports ? lib.optional importHostCredentials defaultHostCredentialImports.geminiOAuth,
      sshForward ? false,
      homeMounts ? [ ],
      publishPorts ? [ ],
      extraVolumes ? [ ],
      network ? null,
    }:
    mkNodeAgent {
      name = "sandboxed-gemini";
      agentCommand = "gemini";
      npmPackage = "@google/gemini-cli";
      passEnv = [
        "GEMINI_API_KEY"
        "GOOGLE_API_KEY"
      ];
      baseAllowedDomains = defaultAllowedDomains ++ [ "generativelanguage.googleapis.com" ];
      inherit hostCredentialImports;
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
        network
        ;
    };

  mkSandboxedShell =
    {
      extraAptPackages ? [ ],
      cpus ? 4,
      memory ? "8g",
      homeMounts ? [ ],
      publishPorts ? [ ],
      extraVolumes ? [ ],
      network ? null,
    }:
    mkSandboxedAgent {
      name = "sandboxed-shell";
      agentCommand = "bash";
      aptPackages = commonAptPackages ++ extraAptPackages;
      allowAllOutbound = true;
      inherit
        cpus
        memory
        homeMounts
        publishPorts
        extraVolumes
        network
        ;
    };
}
