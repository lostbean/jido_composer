# Build the design document

## Status

- This layer is a migration draft.
- The renderer is pinned in the root flake.lock and follows the host's nixpkgs input.
- Run the commands below from the repository root.

## Rebuild and check

```sh
nix run .#design-gate-render -- docs/design docs/design/design-layer.pdf
nix run .#design-gate-check -- docs/design .
```

## Project the authoring library

- The renderer and gate use the bundled library automatically.
- Authors import an ignored local projection of that same library.
- Re-project after changing the renderer pin.

```sh
bundle=$(nix build .#design-gate-bundle --no-link --print-out-paths)
nix run .#design-gate-project -- \
  "$bundle/schema/design-schema.json" docs/design/.render
```

## Review boundary

- A clean gate proves render freshness, valid tokens, and checked links.
- It does not prove implementation conformance or settle pending owner decisions.
- Review the PDF before approving promotion.

## Integration

- The pre-commit hook and CI call the same root-pinned check against the whole repository.
- The former docs-only flake has been removed; the root lock is the single renderer pin.
- OpenSpec records and integrations were removed at the owner's request; their tracked contents remain recoverable from Git.
- Local work tracking is documented in issues/README.md.
- The pinned bundle also provides its matching authoring specification at `skills/design-document-syntax/SKILL.md` inside the bundle path returned above.
- The existing installed design-document-syntax skill provides the authoring entry point; the pinned bundle is the version authority.
