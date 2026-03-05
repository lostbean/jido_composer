# treefmt.nix - Unified code formatting configuration
# Run with: nix fmt or mix fmt
#
# Note: Elixir formatting is handled by `mix format` directly in mix.exs aliases,
# NOT by treefmt. This avoids race conditions when treefmt spawns multiple BEAM
# processes in parallel, which causes "module must be purged" errors with formatter
# plugins (Spark.Formatter, Phoenix.LiveView.HTMLFormatter).
# See: https://github.com/elixir-lang/elixir/issues/7699
{ pkgs, ... }:
{
  projectRootFile = "flake.nix";

  # Nix files - RFC-style is the official Nix format
  programs.nixfmt = {
    enable = true;
    package = pkgs.nixfmt-rfc-style;
  };

  # Shell scripts - shfmt with 2-space indent
  programs.shfmt = {
    enable = true;
    indent_size = 2;
  };

  # YAML files - yamlfmt for GitHub Actions, etc.
  programs.yamlfmt.enable = true;

  # Markdown/JSON via Prettier
  programs.prettier = {
    enable = true;
    includes = [
      "*.md"
      "*.json"
    ];
    excludes = [
      "flake.lock"
    ];
  };

  # Global exclusions
  settings.global.excludes = [
    "*.lock"
    ".git/**"
    "_build/**"
    "deps/**"
    "cover/**"
    "result*"
  ];
}
