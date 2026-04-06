# nix-apple-sandbox

Apple Containers + Nix によるコーディングエージェント向けハードウェアレベルサンドボックス。

各コンテナが独立した軽量 Linux VM として実行される [Apple Containers](https://github.com/apple/containerization) を利用し、エージェントが触れるファイル・使えるツール・通信先を厳密に制御する。

## 前提条件

- Mac with Apple Silicon + macOS 26 (Tahoe)
- [`container` CLI](https://github.com/apple/container/releases) v0.10.0+
- Nix

## クイックスタート

```bash
container system start --enable-kernel-install  # 初回のみ
git clone <this-repo> && cd nix-apple-sandbox
nix develop
nix-apple-sandbox -- claude
```

## `git clone` なしで使う

この repo をローカルに clone しなくても、flake input として直接参照できる。

1. 自分のプロジェクトの `flake.nix` に `github:co3k/nix-apple-sandbox` を追加する
2. `apple-sandbox.lib.${system}.integrateWith pkgs` を取り出す
3. 自分の `devShell` に `sandbox.mkSandboxedCommand { ... }` や `sandbox.mkSandboxedClaudeCode { ... }` を入れる
4. そのプロジェクトで `nix develop` して、生成された `sandboxed-*` / `nix-apple-sandbox` コマンドを実行する

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    apple-sandbox = {
      url = "github:co3k/nix-apple-sandbox";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, apple-sandbox, ... }:
    let
      system = "aarch64-darwin";
      pkgs = nixpkgs.legacyPackages.${system};
      sandbox = apple-sandbox.lib.${system}.integrateWith pkgs;
    in {
      devShells.${system}.default = pkgs.mkShell {
        packages = [
          (sandbox.mkSandboxedCommand {
            extraAptPackages = [ "nodejs" "npm" ];
            extraAllowedDomains = [ "api.openai.com" "generativelanguage.googleapis.com" ];
            installCommands = ''
              RUN npm install -g @anthropic-ai/claude-code @openai/codex @google/gemini-cli
            '';
            homeMounts = [ ".claude" ".agents" ];
            sshForward = true;
          })
        ];
      };
    };
}
```

```bash
container system start --enable-kernel-install  # 初回のみ
cd your-project
nix develop
nix-apple-sandbox -- claude
```

clone が必要なのはこの repo 自体を開発・変更したいときだけで、利用するだけなら不要。

## 既存プロジェクトとの統合

4つの統合パスがある。プロジェクトの環境に応じて選ぶ。
対応するサンプルは `examples/generic-command`, `examples/nix-packages`, `examples/from-devbox`, `examples/from-project-dir` に置いてある。

### パターン1: 任意のエージェント/コマンドを実行する

**「CLI の選択は固定したくない。`nix-apple-sandbox -- <command>` で動かしたい」**

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    apple-sandbox.url = "github:co3k/nix-apple-sandbox";
    apple-sandbox.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { nixpkgs, apple-sandbox, ... }:
    let
      system = "aarch64-darwin";
      pkgs = nixpkgs.legacyPackages.${system};
      sandbox = apple-sandbox.lib.${system}.integrateWith pkgs;
    in {
      devShells.${system}.default = pkgs.mkShell {
        packages = [
          (sandbox.mkSandboxedCommand {
            extraAptPackages = [ "nodejs" "npm" ];
            extraAllowedDomains = [ "api.openai.com" "generativelanguage.googleapis.com" ];
            installCommands = ''
              RUN npm install -g @anthropic-ai/claude-code @openai/codex @google/gemini-cli
            '';
            autoPassEnvByCommand = {
              claude = [ "ANTHROPIC_API_KEY" ];
              codex = [ "OPENAI_API_KEY" ];
              gemini = [ "GEMINI_API_KEY" "GOOGLE_API_KEY" ];
            };
          })
        ];
      };
    };
}
```

```bash
nix develop
nix-apple-sandbox -- claude
nix-apple-sandbox -- codex
nix-apple-sandbox -- gemini
```

`mkSandboxedCommand` は固定の `agentCommand` を持たず、`--` の後ろをそのままコンテナ内で実行する。何も渡さなければ `bash` を起動する。
`autoPassEnvByCommand = { claude = [ "ANTHROPIC_API_KEY" ]; codex = [ "OPENAI_API_KEY" ]; gemini = [ "GEMINI_API_KEY" "GOOGLE_API_KEY" ]; };` のように指定すると、先頭の実行コマンドに応じて必要な env だけを自動転送できる。repo 付属の generic `nix-apple-sandbox` package はこの方式をデフォルトで使う。完全に止めたい場合は `--sandbox-no-auto-pass-env`、特定の env だけ外したい場合は `--sandbox-drop-pass-env NAME` を使う。明示的な `passEnv` や `--sandbox-pass-env` は引き続き追加できる。

CLI の設定ディレクトリを持ち込みたい場合は `homeMounts` を使う。例えば `homeMounts = [ ".claude" ".agents" ];` とすると、ホスト側の `~/.claude` と `~/.agents` がそれぞれ `/root/.claude` と `/root/.agents` にマウントされる。存在しないパスは warning を出してスキップする。

生成された wrapper は実行時 override も受ける。予約済みの `--sandbox-*` オプションだけを wrapper 側で解釈し、それ以外はそのままエージェント CLI に渡す。

```bash
nix-apple-sandbox \
  --sandbox-home-mount .claude \
  --sandbox-home-mount .agents:/root/.agents \
  --sandbox-env FOO=bar \
  --sandbox-cpus 8 \
  --sandbox-memory 16g \
  -- claude --resume
```

```bash
nix-apple-sandbox --sandbox-no-auto-pass-env -- claude
nix-apple-sandbox --sandbox-drop-pass-env ANTHROPIC_API_KEY -- claude
nix-apple-sandbox --sandbox-pass-env OPENAI_API_KEY -- claude
```

runtime で変えられるのは `cpus`, `memory`, `network`, `ssh`, `publishPorts`, `extraVolumes`, `homeMounts`, `passEnv`, 自動 `passEnv` の無効化/除外、追加 env 注入。`aptPackages`, `installCommands`, `extraAllowedDomains`, `allowAllOutbound`, `baseImage` のようなイメージ内容に効く設定は引き続き Nix 側で管理する。

### パターン2: Nix プロジェクト — `nixPackages` で自動マッピング

**「自分の devShell に既にあるパッケージを、サンドボックスにも入れたい」**

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    apple-sandbox.url = "github:co3k/nix-apple-sandbox";
    apple-sandbox.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { nixpkgs, apple-sandbox, ... }:
    let
      system = "aarch64-darwin";
      pkgs = nixpkgs.legacyPackages.${system};
      sandbox = apple-sandbox.lib.${system}.integrateWith pkgs;

      projectPackages = with pkgs; [ go gopls postgresql ];
    in {
      devShells.${system}.default = pkgs.mkShell {
        packages = projectPackages ++ [
          (sandbox.mkSandboxedClaudeCode {
            # Nix パッケージを渡すと apt 名に自動変換される
            # pkgs.go → "golang-go", pkgs.postgresql → "postgresql-client"
            nixPackages = projectPackages;
            sshForward = true;
          })
        ];
      };
    };
}
```

`nixPackages` は `extraAptPackages` と併用できる。マッピングにない Nix パッケージはスキップされ、ビルドログに警告が出る。

### パターン3: devbox プロジェクト — `fromDevboxJson` で自動構成

**「devbox.json にパッケージが宣言済み。それをそのまま使いたい」**

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    apple-sandbox.url = "github:co3k/nix-apple-sandbox";
    apple-sandbox.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { nixpkgs, apple-sandbox, ... }:
    let
      system = "aarch64-darwin";
      pkgs = nixpkgs.legacyPackages.${system};
      sandbox = apple-sandbox.lib.${system}.integrateWith pkgs;
    in {
      devShells.${system}.default = pkgs.mkShell {
        packages = [
          # devbox.json の "packages" を読み取り、apt 名にマッピング
          # "go@1.22" → "golang-go", "python@3.12" → "python3", etc.
          (sandbox.fromDevboxJson ./devbox.json {
            sshForward = true;
          })
        ];
      };
    };
}
```

devbox をメインの環境管理に使い、サンドボックスだけ Nix flake で定義する構成。`fromDevboxJsonWith` でエージェントプリセットを選択可能。

### パターン4: 自動検出 — `fromProjectDir` でゼロ設定

**「設定ファイルを見て勝手に判断してほしい」**

```nix
(sandbox.fromProjectDir ./. { cpus = 4; memory = "8g"; })
```

プロジェクトルートをスキャンし、検出したファイルに応じて構成する:

| ファイル | 追加パッケージ | 追加ドメイン |
|---|---|---|
| `go.mod` | golang-go | proxy.golang.org, sum.golang.org |
| `package.json` | nodejs, npm | registry.npmjs.org, registry.yarnpkg.com |
| `Cargo.toml` | rustc, cargo | crates.io, static.crates.io |
| `pyproject.toml` / `requirements.txt` | python3, pip, venv | pypi.org, files.pythonhosted.org |
| `Gemfile` | ruby-full | rubygems.org |
| `pom.xml` / `build.gradle` | default-jdk | — |

複数の言語が混在するプロジェクトでは全て検出される。

### パターン5: 手動（既存のまま）

`extraAptPackages` を直接指定する従来の方法も引き続き使える。

```nix
(sandbox.mkSandboxedClaudeCode {
  extraAptPackages = [ "golang-go" "postgresql-client" ];
})
```

## API レベル

| レベル | 関数 | 用途 |
|---|---|---|
| **High** | `integrateWith pkgs` | `nixPackages`, `fromDevboxJson`, `fromProjectDir` + 全プリセット |
| **Mid** | `presetsWith pkgs` | エージェント別プリセット（`extra*` パラメータ） |
| **Low** | `mkSandboxedAgentWith pkgs` | 全パラメータを直接制御 |

`*With` 版は呼び出し側の `pkgs` を受け取る。`nixpkgs.follows` と組み合わせてパッケージの二重ダウンロードを防ぐ。

### `mkSandboxedCommand { ... }` (integrate レベル)

```nix
mkSandboxedCommand {
  name                ? "nix-apple-sandbox"
  nixPackages         ? []     # Nix derivations → apt に自動マッピング
  extraAptPackages    ? []
  extraAllowedDomains ? []
  installCommands     ? ""     # 実行したい CLI のインストール処理
  passEnv             ? []     # 必要なら認証・設定用 env を転送
  autoPassEnvByCommand ? {}    # { claude = [ "ANTHROPIC_API_KEY" ]; ... }
  homeMounts          ? []     # [".claude" ".agents:/root/.agents"]
  cpus                ? 4
  memory              ? "8g"
  allowAllOutbound    ? false
  sshForward          ? false
  publishPorts        ? []
  extraVolumes        ? []
  network             ? null
}
```

生成されるコマンドは `nix-apple-sandbox -- <command>` の形で使う。何も渡さなければ `bash` を起動する。
reserved runtime options として `--sandbox-cpus`, `--sandbox-memory`, `--sandbox-pass-env`, `--sandbox-drop-pass-env`, `--sandbox-no-auto-pass-env`, `--sandbox-env`, `--sandbox-home-mount`, `--sandbox-volume`, `--sandbox-publish`, `--sandbox-network`, `--sandbox-no-network`, `--sandbox-ssh`, `--sandbox-no-ssh` を受ける。

### `mkSandboxedClaudeCode { ... }` (integrate レベル)

```nix
mkSandboxedClaudeCode {
  nixPackages         ? []     # Nix derivations → apt に自動マッピング
  extraAptPackages    ? []     # 手動で追加する apt パッケージ
  extraAllowedDomains ? []     # ネットワーク制御時の追加ドメイン
  homeMounts          ? []     # [".claude" ".agents"]
  cpus                ? 4
  memory              ? "8g"
  allowAllOutbound    ? false  # true で全通信許可、false でドメインフィルタ有効
  sshForward          ? false
  publishPorts        ? []     # ["8080:3000"]
  extraVolumes        ? []     # ["/absolute/host/path:/guest/path"]
  network             ? null
}
```

`mkSandboxedCodex`, `mkSandboxedGemini`, `mkSandboxedShell` も同様。これらは convenience preset で、コアは `mkSandboxedCommand` / `mkSandboxedAgent`。
固定コマンド preset でも runtime override は使える。例えば `sandboxed-claude-code --sandbox-home-mount .claude -- --resume` のように、wrapper option を先に置いて `--` で区切ればよい。

## ファイル構成

```
nix-apple-sandbox/
├── flake.nix                              # エントリポイント
├── lib/
│   ├── mkSandboxedAgent.nix               # コア（Containerfile → build → run）
│   ├── presets.nix                        # エージェント別プリセット
│   ├── integrate.nix                      # 統合ヘルパー（nixPackages 等）
│   └── packageMap.nix                     # Nix→apt パッケージマッピング
├── scripts/
│   └── sandbox-ctl.sh                     # 管理ユーティリティ
└── examples/
    ├── generic-command/flake.nix          # mkSandboxedCommand
    ├── nix-packages/flake.nix             # nixPackages 統合
    ├── from-devbox/{flake.nix,devbox.json} # fromDevboxJson 統合
    └── from-project-dir/{flake.nix,package.json} # fromProjectDir 自動検出
```

## 管理

```bash
./scripts/sandbox-ctl.sh status    # 状態確認
./scripts/sandbox-ctl.sh rebuild   # イメージ再構築をトリガー
./scripts/sandbox-ctl.sh clean     # 全削除
./scripts/sandbox-ctl.sh list      # 実行中コンテナ一覧
./scripts/sandbox-ctl.sh stop-all  # 全コンテナ停止
./scripts/sandbox-ctl.sh logs NAME # コンテナログ表示
./scripts/sandbox-ctl.sh disk      # ディスク使用量
```

## 隔離モデル

```
macOS ホスト
└── container run
    └── Lightweight Linux VM (Virtualization.framework)
        ├── 独自 Linux カーネル（ハードウェア隔離）
        ├── /workspace ← カレントディレクトリのみ
        ├── 宣言されたツールだけが存在
        └── エージェント
```

| 比較 | カーネル | 隔離 |
|---|---|---|
| Seatbelt (sandbox-exec) | macOS 共有 | プロセスレベル（deprecated） |
| jail.nix (bubblewrap) | Linux 共有 | namespace |
| Docker Sandbox | Linux 独立 | MicroVM |
| **nix-apple-sandbox** | **Linux 独立** | **VM per container** |

## 既知の制限

- Apple Containers pre-1.0: マイナーバージョン間で breaking change の可能性
- macOS 26 + Apple Silicon 限定
- 初回イメージビルドに 2-3 分
- ネットワーク制御はカーネル依存（best-effort、netfilter 必須）
- パッケージマッピング（packageMap.nix）は主要パッケージのみカバー

## ライセンス

Apache-2.0
