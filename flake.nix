{
  description = "jido_composer - Composable agent flows via FSM for the Jido ecosystem";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    # Code formatting
    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";
  };
  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-unstable,
      flake-utils,
      treefmt-nix,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        unstable-packages = final: _prev: {
          unstable = import nixpkgs-unstable {
            inherit system;
            config.allowUnfree = true;
          };
        };

        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true;
          overlays = [
            unstable-packages
          ];
        };

        isDarwin = builtins.match ".*-darwin" pkgs.stdenv.hostPlatform.system != null;

        # Single source of truth for Elixir/Erlang packages
        beamPackages = pkgs.unstable.beamMinimal28Packages;
        elixir = beamPackages.elixir_1_19;

        # Code formatting via treefmt (Nix, shell, Markdown, JSON, YAML)
        # Note: Elixir is handled by `mix format` directly to avoid race conditions
        treefmtEval = treefmt-nix.lib.evalModule pkgs {
          imports = [ ./treefmt.nix ];
        };

        # ============================================================
        # Shared packages (used by both dev and CI shells)
        # Single source of truth - ensures dev/CI parity
        # ============================================================
        basePackages = with pkgs; [
          # Elixir/Erlang runtime
          elixir
          beamPackages.erlang
          beamPackages.rebar3

          # Code formatting & validation
          treefmtEval.config.build.wrapper
          nixfmt-rfc-style
        ];

        # Platform-specific packages
        platformPackages = with pkgs; if isDarwin then [ ] else [ inotify-tools ];

        # ============================================================
        # Dev-only packages (interactive development tools)
        # ============================================================
        devOnlyPackages = [
          pkgs.lefthook
          pkgs.claude-code
        ];

        # ============================================================
        # Shell definitions
        # ============================================================

        # Full development shell
        devShell = pkgs.mkShell {
          buildInputs = basePackages ++ devOnlyPackages ++ platformPackages;
          shellHook = ''
            # Install lefthook git hooks if not already installed
            if [ ! -f .git/hooks/pre-commit ] || ! grep -q "lefthook" .git/hooks/pre-commit 2>/dev/null; then
              lefthook install > /dev/null 2>&1 && echo "Lefthook git hooks installed"
            fi
          '';
        };

        # Minimal CI shell - only what's needed for `mix ci`
        ciShell = pkgs.mkShell {
          buildInputs = basePackages ++ platformPackages;
          shellHook = ''
            echo "CI shell ready"
          '';
        };

      in
      {
        devShells = {
          default = devShell;
          ci = ciShell;
        };

        # Unified formatter - enables `nix fmt`
        formatter = treefmtEval.config.build.wrapper;

        # Formatting check - enables `nix flake check` for formatting
        checks.formatting = treefmtEval.config.build.check self;
      }
    );
}
