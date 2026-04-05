{ pkgs }:
let
  lib = pkgs.lib;

  mappings = {
    autoconf = [ "autoconf" ];
    automake = [ "automake" ];
    bash = [ "bash" ];
    black = [ "black" ];
    ca-certificates = [ "ca-certificates" ];
    cacert = [ "ca-certificates" ];
    cargo = [ "cargo" ];
    clang = [ "clang" ];
    cmake = [ "cmake" ];
    consul = [ ];
    coreutils = [ "coreutils" ];
    curl = [ "curl" ];
    deadnix = [ ];
    default-jdk = [ "default-jdk" ];
    deno = [ "deno" ];
    diffutils = [ "diffutils" ];
    docker = [ "docker.io" ];
    docker-client = [ "docker.io" ];
    dotnet-sdk = [ "dotnet-sdk-8.0" ];
    elixir = [ "elixir" ];
    erlang = [ "erlang" ];
    fd = [ "fd-find" ];
    fd-find = [ "fd-find" ];
    file = [ "file" ];
    findutils = [ "findutils" ];
    fzf = [ "fzf" ];
    gawk = [ "gawk" ];
    gcc = [ "gcc" ];
    git = [ "git" ];
    glibc = [ ];
    gnumake = [ "make" ];
    gnupg = [ "gnupg" ];
    gnused = [ "sed" ];
    gnugrep = [ "grep" ];
    gnutar = [ "tar" ];
    go = [ "golang-go" ];
    go-task = [ ];
    golang = [ "golang-go" ];
    golang-go = [ "golang-go" ];
    golangci-lint = [ ];
    google-cloud-sdk = [ ];
    gopls = [ ];
    grep = [ "grep" ];
    gzip = [ "gzip" ];
    htop = [ "htop" ];
    jdk = [ "default-jdk" ];
    jq = [ "jq" ];
    kubectl = [ ];
    less = [ "less" ];
    libffi = [ "libffi-dev" ];
    libgcc = [ "libgcc-s1" ];
    libtool = [ "libtool" ];
    libxml2 = [ "libxml2-dev" ];
    libxslt = [ "libxslt1-dev" ];
    libyaml = [ "libyaml-dev" ];
    lua = [ "lua5.4" ];
    make = [ "make" ];
    maven = [ "maven" ];
    meson = [ "meson" ];
    mysql = [ "mysql-client" ];
    mysql-client = [ "mysql-client" ];
    mysql80 = [ "mysql-client" ];
    ncurses = [ "libncurses-dev" ];
    neovim = [ "neovim" ];
    nil = [ ];
    ninja = [ "ninja-build" ];
    nixfmt-rfc-style = [ ];
    nodejs = [ "nodejs" "npm" ];
    nodejs-slim = [ "nodejs" ];
    nodejs-18 = [ "nodejs" "npm" ];
    nodejs-20 = [ "nodejs" "npm" ];
    nodejs-22 = [ "nodejs" "npm" ];
    npm = [ "npm" ];
    openjdk = [ "default-jdk" ];
    openjdk17 = [ "openjdk-17-jdk" ];
    openjdk21 = [ "openjdk-21-jdk" ];
    openssh = [ "openssh-client" ];
    openssh-client = [ "openssh-client" ];
    openssl = [ "libssl-dev" ];
    packer = [ ];
    patch = [ "patch" ];
    perl = [ "perl" ];
    php = [ "php" ];
    pkg-config = [ "pkg-config" ];
    pkgconf = [ "pkg-config" ];
    postgresql = [ "postgresql-client" ];
    postgresql-client = [ "postgresql-client" ];
    procps = [ "procps" ];
    protobuf = [ "protobuf-compiler" ];
    python = [ "python3" "python3-pip" "python3-venv" ];
    python3 = [ "python3" "python3-pip" "python3-venv" ];
    python311 = [ "python3" "python3-pip" "python3-venv" ];
    python312 = [ "python3" "python3-pip" "python3-venv" ];
    python313 = [ "python3" "python3-pip" "python3-venv" ];
    python3-full = [ "python3" "python3-pip" "python3-venv" ];
    python3-pip = [ "python3-pip" ];
    python3-venv = [ "python3-venv" ];
    readline = [ "libreadline-dev" ];
    redis = [ "redis-tools" ];
    redis-cli = [ "redis-tools" ];
    ripgrep = [ "ripgrep" ];
    ruby = [ "ruby-full" ];
    ruby-full = [ "ruby-full" ];
    ruff = [ "ruff" ];
    rust-analyzer = [ ];
    rustc = [ "rustc" ];
    sccache = [ ];
    sed = [ "sed" ];
    shellcheck = [ "shellcheck" ];
    sqlite = [ "sqlite3" ];
    sqlite3 = [ "sqlite3" ];
    statix = [ ];
    stdenv = [ ];
    terraform = [ ];
    tmux = [ "tmux" ];
    tree = [ "tree" ];
    unzip = [ "unzip" ];
    vault = [ ];
    vim = [ "vim" ];
    wget = [ "wget" ];
    awscli2 = [ ];
    yarn = [ "yarnpkg" ];
    yarnpkg = [ "yarnpkg" ];
    yq-go = [ "yq" ];
    zip = [ "zip" ];
    zlib = [ "zlib1g-dev" ];
  };

  normalizeName = pkg:
    let
      rawName =
        if builtins.isString pkg then
          pkg
        else if builtins.isAttrs pkg && pkg ? pname then
          pkg.pname
        else if builtins.isAttrs pkg && pkg ? name then
          (builtins.parseDrvName pkg.name).name
        else
          throw "packageMap.resolve expects derivations or strings";
    in lib.toLower (lib.replaceStrings [ "_" ] [ "-" ] rawName);

  emitWarnings = result:
    lib.foldl'
      (acc: name:
        builtins.trace
          "nix-apple-sandbox: no apt mapping for `${name}`; skipping"
          acc)
      result
      result.unmapped;
in {
  resolve = packages:
    let
      folded = lib.foldl'
        (acc: pkg:
          let
            key = normalizeName pkg;
            mapped =
              if builtins.hasAttr key mappings then
                builtins.getAttr key mappings
              else
                null;
          in
            if mapped == null then
              acc // { unmapped = acc.unmapped ++ [ key ]; }
            else
              acc // { aptPackages = acc.aptPackages ++ mapped; })
        { aptPackages = [ ]; unmapped = [ ]; }
        packages;

      result = {
        aptPackages = lib.unique folded.aptPackages;
        unmapped = lib.unique folded.unmapped;
      };
    in emitWarnings result;
}
