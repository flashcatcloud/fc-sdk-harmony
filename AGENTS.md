# Agent guide

Notes for anyone (human or coding agent) changing or releasing this repository.

## Branches

| Branch | Role |
|---|---|
| `main` | Single source of truth. Every change lands here first, through a pull request. |
| `publish` | Release branch. It receives `main`, through a `main` → `publish` pull request merged with a merge commit — or, for a patch release while `main` holds unreleased work, a hotfix branch (see below). Apart from merge commits and patch-release version bumps it holds nothing that is not on `main`. |
| `dev` | Unused since June 2026. Do not target it. |
| feature branches | One change per branch, cut from `main`, pull request into `main`. |

- Never commit or merge anything into `publish` that is not also on `main` — not even CI fixes. A change made only on `publish` is lost from `main` and silently diverges the two. The one exception is a patch release's version bump (below); its fix must reach `main` too.
- Never force-push, and never move or delete a release tag.
- Stacked work (a branch based on another open pull request) is fine; once the base merges, bring the branch up to date by merging `main` into it, not by rebasing a pushed branch.

## Releasing the SDK packages (OHPM)

The five packages `@flashcatcloud/core`, `rum`, `crash`, `trace` and `axios` are released together, always at the same version.

1. **Version** — on `main`, through a pull request, set the version in:
   - the `version` of every `flashcat-*/oh-package.json5`, and the `@flashcatcloud/core` / `@flashcatcloud/trace` dependency pins between the packages;
   - `SDK_VERSION` in `flashcat-core/src/main/ets/internal/Version.ets`;
   - test fixtures that spell the version out (search the `src/test` folders for the previous version).

   In each module's `CHANGELOG.md`, the `Unreleased` section becomes the new version.
2. **Publish branch** — open a pull request from `main` to `publish` and merge it with a merge commit.
3. **Tag the tip of `publish`**:

   ```sh
   git fetch origin
   git tag -a harmony-sdk-vX.Y.Z origin/publish -m "HarmonyOS SDK X.Y.Z"
   git push origin harmony-sdk-vX.Y.Z
   ```

   `publish-ohpm.yml` refuses a tag that is not the tip of `publish`, or whose version differs from `flashcat-core/oh-package.json5`. It builds and publishes the tagged commit, so the tag must be the `publish` tip — a tag on the `main` commit would build `main`'s tree and workflow, not what `publish` holds.
4. **Runner** — the publish job runs on a self-hosted runner labelled `harmony`; it must be online before the tag is pushed.
5. **Done means installable** — OHPM reviews every published package by hand; until then `ohpm info @flashcatcloud/core@X.Y.Z` fails. A release is complete only when all five packages install at the new version in an empty project and report the new `SDK_VERSION`, not when the workflow turns green.

A manual run (`workflow_dispatch`) is only accepted on `publish`, defaults to a dry run, and needs `confirm_publish=yes` to publish.

## Patch release while `main` holds unreleased work

When `main` already carries work that must not ship yet, a patch (X.Y.Z+1) is cut from the released state instead of from `main`:

1. Branch from `publish`: `git switch -c hotfix/X.Y.Z origin/publish`. Commit the fix, then the version bump (same files as step 1 above; the `CHANGELOG.md` sections get the new version directly).
2. Open a pull request from the hotfix branch into `publish` and merge it with a merge commit.
3. Tag the tip of `publish` and publish exactly as in the steps above.
4. Land the same fix on `main` through its own pull request (ported, not merged from `publish`, when the code has moved on), so nothing exists only on `publish`. The version bump stays on `publish`; `main` moves on to its next version, and its `CHANGELOG.md` records the patch under its own version heading.

## Releasing the hvigor plugin (npm)

`@flashcatcloud/hvigor-plugin` has its own version and tag prefix: `hvigor-plugin-vX.Y.Z`, handled by `publish-hvigor-plugin.yml`. Same rules: land on `main`, merge `main` into `publish`, tag the tip of `publish`.

## Public repository

This repository is public, and its history cannot be rewritten. Commit messages, code comments, test names, branch names and pull request text describe the change on its technical merits only — no customer or user identifiers, no internal tickets, reports, environments or credentials, and no reference to how an issue was found. Write them in English.
