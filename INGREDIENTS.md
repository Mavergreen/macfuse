# Ingredients

Everything baked into macFUSE for Mavericks, where it is pinned and what moves it.

| Ingredient | Pinned in | Tracked by | A bump |
|---|---|---|---|
| macFUSE | `UPSTREAM_VERSION` (bare upstream release; the tag is `macfuse-<version>`) | `github-releases` on `macfuse/macfuse`, `extractVersionTemplate` `^macfuse-(?<version>.+)$` | a new upstream release, `<version>-mavericks.1` |

No upstream release notes beyond the link: `build/upstream-release-notes-url.sh` links `https://github.com/macfuse/macfuse/releases/tag/macfuse-<version>`.

## Declared state

- upstream: UPSTREAM_VERSION

## Conformance deviations

- native-build:closed-helpers: a native 10.9 build cannot read the upstream dmg (APFS), so it lacks the closed helpers that ship only in the dmg. Exit: shipyard QUEUE "A dmg/APFS reader that runs on 10.9 and Linux".
