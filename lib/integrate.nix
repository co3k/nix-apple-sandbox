{ pkgs }:
let
  lib = pkgs.lib;
  presets = import ./presets.nix { inherit pkgs; };
  packageMap = import ./packageMap.nix { inherit pkgs; };

  mergeResolvedPresetPackages = args:
    let
      resolved = packageMap.resolve (args.nixPackages or [ ]);
    in (builtins.removeAttrs args [ "nixPackages" ]) // {
      extraAptPackages = (args.extraAptPackages or [ ]) ++ resolved.aptPackages;
    };

  mergeResolvedAgentPackages = args:
    let
      cleanArgs = builtins.removeAttrs args [ "nixPackages" ];
      resolved = packageMap.resolve (args.nixPackages or [ ]);
      baseAptPackages =
        if cleanArgs ? aptPackages then cleanArgs.aptPackages else presets.commonAptPackages;
    in cleanArgs // {
      aptPackages = baseAptPackages ++ resolved.aptPackages;
    };

  wrapPreset = presetFn: args: presetFn (mergeResolvedPresetPackages args);

  stripDevboxVersion = packageName:
    let
      match = builtins.match "([^@]+)(@.*)?" packageName;
    in if match == null then packageName else builtins.elemAt match 0;

  readDevboxPackages = devboxPath:
    let
      parsed = builtins.fromJSON (builtins.readFile devboxPath);
    in map stripDevboxVersion (parsed.packages or [ ]);

  detectProject = projectDir:
    let
      has = relativePath: builtins.pathExists (projectDir + "/${relativePath}");
      pythonDetected = has "pyproject.toml" || has "requirements.txt";

      detections = [
        {
          enabled = has "go.mod";
          aptPackages = [ "golang-go" ];
          allowedDomains = [ "proxy.golang.org" "sum.golang.org" ];
        }
        {
          enabled = has "package.json";
          aptPackages = [ "nodejs" "npm" ];
          allowedDomains = [ "registry.npmjs.org" "registry.yarnpkg.com" ];
        }
        {
          enabled = has "Cargo.toml";
          aptPackages = [ "rustc" "cargo" ];
          allowedDomains = [ "crates.io" "static.crates.io" ];
        }
        {
          enabled = pythonDetected;
          aptPackages = [ "python3" "python3-pip" "python3-venv" ];
          allowedDomains = [ "pypi.org" "files.pythonhosted.org" ];
        }
        {
          enabled = has "Gemfile";
          aptPackages = [ "ruby-full" ];
          allowedDomains = [ "rubygems.org" ];
        }
        {
          enabled = has "pom.xml" || has "build.gradle";
          aptPackages = [ "default-jdk" ];
          allowedDomains = [ ];
        }
      ];

      active = builtins.filter (detection: detection.enabled) detections;
    in {
      aptPackages = lib.unique (lib.concatMap (detection: detection.aptPackages) active);
      allowedDomains = lib.unique (lib.concatMap (detection: detection.allowedDomains) active);
    };
in {
  inherit packageMap;
  inherit (presets) commonAptPackages defaultAllowedDomains;

  mkSandboxedAgent = args: presets.mkSandboxedAgent (mergeResolvedAgentPackages args);

  mkSandboxedCommand = wrapPreset presets.mkSandboxedCommand;
  mkSandboxedClaudeCode = wrapPreset presets.mkSandboxedClaudeCode;
  mkSandboxedCodex = wrapPreset presets.mkSandboxedCodex;
  mkSandboxedGemini = wrapPreset presets.mkSandboxedGemini;
  mkSandboxedShell = wrapPreset presets.mkSandboxedShell;

  fromDevboxJson = devboxPath: args:
    let
      devboxPackages = readDevboxPackages devboxPath;
    in wrapPreset presets.mkSandboxedClaudeCode (args // {
      nixPackages = (args.nixPackages or [ ]) ++ devboxPackages;
    });

  fromDevboxJsonWith = devboxPath: presetFn: args:
    let
      devboxPackages = readDevboxPackages devboxPath;
    in wrapPreset presetFn (args // {
      nixPackages = (args.nixPackages or [ ]) ++ devboxPackages;
    });

  fromProjectDir = projectDir: args:
    let
      detected = detectProject projectDir;
    in wrapPreset presets.mkSandboxedClaudeCode (args // {
      extraAptPackages = (args.extraAptPackages or [ ]) ++ detected.aptPackages;
      extraAllowedDomains = (args.extraAllowedDomains or [ ]) ++ detected.allowedDomains;
    });

  fromProjectDirWith = projectDir: presetFn: args:
    let
      detected = detectProject projectDir;
    in wrapPreset presetFn (args // {
      extraAptPackages = (args.extraAptPackages or [ ]) ++ detected.aptPackages;
      extraAllowedDomains = (args.extraAllowedDomains or [ ]) ++ detected.allowedDomains;
    });
}
