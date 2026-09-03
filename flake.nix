{
  description = "jido_composer - Composable agent flows via FSM for the Jido ecosystem";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    design-layer.url = "github:lostbean/design-layer/3c121908af93d57bfc7f80da3f3aff63c5478c8b";
    design-layer.inputs.nixpkgs.follows = "nixpkgs";

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
      design-layer,
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
        beamPackages = pkgs.unstable.beamMinimal29Packages;
        elixir = beamPackages.elixir_1_20;

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

        # Each compatibility shell keeps compiled BEAM files separate locally.
        compatibilityShell =
          elixirVersion: otpVersion:
          let
            beam = pkgs.unstable.${"beamMinimal${otpVersion}Packages"};
          in
          pkgs.mkShell {
            buildInputs = [
              beam.${"elixir_${elixirVersion}"}
              beam.erlang
              beam.rebar3
            ]
            ++ platformPackages;
            shellHook = ''
              export MIX_BUILD_ROOT="$PWD/_build/compat/elixir-${elixirVersion}-otp-${otpVersion}"
              export MIX_DEPS_PATH="$PWD/_build/compat/elixir-${elixirVersion}-otp-${otpVersion}/deps"
            '';
          };

      in
      {
        apps.design-gate-check = design-layer.apps.${system}.check;
        apps.design-gate-render = design-layer.apps.${system}.render;
        apps.design-gate-project = design-layer.apps.${system}.project;
        packages.design-gate-bundle = design-layer.packages.${system}.gate-bundle;

        devShells = {
          default = devShell;
          ci = ciShell;
          ci-1_18-27 = compatibilityShell "1_18" "27";
          ci-1_19-27 = compatibilityShell "1_19" "27";
          ci-1_19-28 = compatibilityShell "1_19" "28";
          ci-1_20-27 = compatibilityShell "1_20" "27";
          ci-1_20-28 = compatibilityShell "1_20" "28";
          ci-1_20-29 = compatibilityShell "1_20" "29";
        };

        # Unified formatter - enables `nix fmt`
        formatter = treefmtEval.config.build.wrapper;

        # Formatting check - enables `nix flake check` for formatting
        checks.formatting = treefmtEval.config.build.check self;
      }
    );
}
