# Ingredients

Everything baked into macFUSE for Mavericks, where it is pinned and what moves it.

| Ingredient | Pinned in | Tracked by | A bump |
|---|---|---|---|
| macFUSE | `UPSTREAM_VERSION` (bare upstream release; the tag is `macfuse-<version>`) | `github-releases` on `macfuse/macfuse`, `extractVersionTemplate` `^macfuse-(?<version>.+)$` | a new upstream release, `<version>-mavericks.1` |

No upstream release notes beyond the link: `build/upstream-release-notes-url.sh` links `https://github.com/macfuse/macfuse/releases/tag/macfuse-<version>`.

## Declared state

- upstream: UPSTREAM_VERSION

## Conformance deviations

None.
