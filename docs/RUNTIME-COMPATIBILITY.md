# Runtime compatibility

## Checked combinations

- The development and quality-check shells use Elixir 1.20 on OTP 29. `flake.lock` pins the exact patch versions.
- CI checks the following combinations. Each compatibility job has separate dependency and build directories; caches also include the toolchain, environment, and lock files. `MIX_BUILD_ROOT` preserves Mix's separate production and test build subdirectories.

| Elixir | OTP | Check           | Local Nix shell |
| ------ | --- | --------------- | --------------- |
| 1.18   | 27  | Full test suite | `ci-1_18-27`    |
| 1.19   | 27  | Full test suite | `ci-1_19-27`    |
| 1.19   | 28  | Full test suite | `ci-1_19-28`    |
| 1.20   | 27  | Full test suite | `ci-1_20-27`    |
| 1.20   | 28  | Full test suite | `ci-1_20-28`    |
| 1.20   | 29  | Full test suite | `ci-1_20-29`    |

- The package permits Elixir 1.18 and later 1.x releases. This requirement does not certify every Elixir/OTP combination.
- The test-only `agent_obs` dependency requires version 0.1.7 or later in the 0.1 series, which permits Elixir 1.18. Every matrix job includes test dependencies and runs the full suite.
- Formatting, documentation, and lint checks run once on the development toolchain. Compatibility jobs compile project code with warnings treated as errors and do not impose older formatter output.
- Tests replay recorded provider responses with a non-secret API-key placeholder. They do not validate live provider behavior or cassette recording.

## Local checks

- Run the oldest full-suite combination:

```sh
nix develop .#ci-1_18-27 --command env MIX_ENV=test mix deps.get --check-locked
nix develop .#ci-1_18-27 --command env MIX_ENV=test mix deps.compile
nix develop .#ci-1_18-27 --command env MIX_ENV=test mix compile --warnings-as-errors
nix develop .#ci-1_18-27 --command env MIX_ENV=test ANTHROPIC_API_KEY=test-cassette-key RECORD_CASSETTES=false mix test
```

- Run a full-suite combination:

```sh
nix develop .#ci-1_20-28 --command env MIX_ENV=test mix deps.get --check-locked
nix develop .#ci-1_20-28 --command env MIX_ENV=test ANTHROPIC_API_KEY=test-cassette-key RECORD_CASSETTES=false mix test
```

## Toolchain updates

- Refresh the BEAM package input with `nix flake update nixpkgs-unstable`, then run the quality checks and compatibility matrix. This command leaves the independent design-tooling input pinned.
- Review the [Elixir compatibility table](https://elixir.hexdocs.pm/compatibility-and-deprecations.html) before adding a combination. Elixir 1.18 supports OTP 25–27; 1.19 supports OTP 26–28; 1.20 supports OTP 27–29. This project checks only the subset listed above.
- Add a matching Nix shell and CI matrix entry when adopting another runtime line. CI runs on pushes, pull requests, and manual dispatch; it does not automatically change toolchain pins.
- Elixir 1.21 is planned for November 2026 in the [upstream roadmap](https://elixir-lang.org/blog/2026/01/09/type-inference-of-all-and-next-15/). That date is a plan, not a release guarantee; no unreleased runtime is included in the required matrix.
