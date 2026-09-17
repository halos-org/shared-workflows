# Hat Labs Shared Workflows

Reusable GitHub Actions workflows for halos-org and hatlabs repositories: pull request checks, Debian package builds, GitHub releases, APT and npm publication, container image update checks, and translated documentation gates.

## Overview

A caller composes the workflows its repository needs. A Debian package repository calls `build-deb.yml` and `apt-publish.yml`; an npm package repository calls `publish-npm.yml`; neither calls the other's. No workflow builds a package unless the caller asks for it.

| Caller file | Debian package | npm package | Tag-only | Debian and npm |
|---|---|---|---|---|
| `pr.yml` | `checks`, `build-deb`, `status` | `checks`, `status` | `checks`, `status` | `checks`, `build-deb`, `status` |
| `main.yml` | tests, `release-version` → `build-deb` → `stage-release` → `apt-publish` (unstable) | tests, `release-version` → `stage-release` | tests, `release-version` → `stage-release` | tests, `release-version` → `build-deb` → `stage-release` → `apt-publish` (unstable) |
| `release.yml` | `apt-publish` (stable) | `publish-npm` | none | `apt-publish` (stable), `publish-npm` |

The release flow for every packaged repository:

1. **Pull request:** tests, version checks, and for Debian packages a build with lintian.
2. **Merge to main:** a pre-release `v<upstream>+<N>_pre` and a draft `v<upstream>+<N>`, both tagging the merged commit. Debian packages are attached and dispatched to the APT unstable channel.
3. **Publish the draft:** Debian packages are dispatched to the APT stable channel, and npm packages are published to npm.

Copy the caller files from `examples/`: [deb](examples/deb/.github/workflows), [npm](examples/npm/.github/workflows), and [docs-repo](examples/docs-repo/.github/workflows) for translated documentation. A tag-only repository uses the npm example's `pr.yml` and `main.yml` and has no `release.yml`.

## Versioning

Releases are tagged `vX.Y.Z`. Each full release also moves the major tag `vX` to the newest `vX.*.*` release; release candidates (`vX.Y.Z-rc.N`) do not. Breaking changes to any of these ship as a new major: workflow names, inputs, secrets and outputs; the required local actions and the arguments passed to local script overrides; the permissions a calling job must grant; the `concurrency` requirement on `main.yml`; and the `VERSION` and tag formats.

Pin the major tag:

```yaml
uses: halos-org/shared-workflows/.github/workflows/<workflow>.yml@v1
```

Only the workflows documented below are part of `v1`. See [Legacy workflows](#legacy-workflows) for `pr-checks.yml`, `build-release.yml` and `publish-stable.yml`.

## Required status check

A reusable-workflow call reports its checks as `<caller job> / <called job>`, so a check name required by branch protection would change whenever a job in this repository is renamed. Every caller's `pr.yml` therefore ends with a `status` job of its own, and branch protection requires `status` only:

```yaml
  # Branch protection requires only this job. List every other job in needs,
  # including jobs defined in this file.
  status:
    needs: [checks, build-deb]
    if: always()
    runs-on: ubuntu-latest
    permissions: {}
    steps:
      - name: Require every job to succeed
        env:
          NEEDS: ${{ toJSON(needs) }}
        run: jq -e 'all(.[]; .result == "success")' <<< "$NEEDS"
```

`if: always()` makes the job run when a dependency fails. Without it, a failed dependency skips `status`, and GitHub counts a skipped required check as passing, so the pull request could merge. The `jq` filter fails on `skipped` too. If a caller makes one of its jobs conditional, it has to allow `skipped` for that job.

## Workflows

A called workflow cannot get more token permissions than its calling job grants. Every workflow here needs at least `contents: read`; sections below name the extra permissions a workflow needs.

### checks.yml

Pull request checks for every caller. Jobs:

- **tests** runs the caller's `.github/actions/run-tests` action.
- **version-check** runs `.github/actions/check-versions` if the caller has it, for example to keep `VERSION` equal to `package.json`.
- **version-bump-check** calls [version-bump-check.yml](#version-bump-checkyml).

| Input | Type | Default | Description |
|---|---|---|---|
| `runs-on` | string | `ubuntu-latest` | Runner to use for every job |

### build-deb.yml

Builds Debian packages with the caller's `.github/actions/build-deb` action and runs lintian on every `.deb` in the repository root or `build/`. The run fails when the build produces no package, and when lintian reports an error or a warning. To suppress a lintian tag, add `debian/<package>.lintian-overrides`.

The workflow has two modes:

- **Check mode**, from `pr.yml`: call with no release inputs. Nothing is uploaded.
- **Release mode**, from `main.yml`: pass `revision` and every other release input, normally from `release-version.yml`. The workflow writes `debian/changelog` from the commit subjects since the last stable tag, builds, renames `<package-name>_<debian-version>_all.deb` to `<package-name>_<debian-version>_all+<distro>+<component>.deb`, and uploads every `.deb` as the artifact named in the `artifact` output.

Passing some release inputs without `revision`, or `revision` without all of them, fails the run.

| Input | Type | Default | Description |
|---|---|---|---|
| `runs-on` | string | `ubuntu-latest` | Runner to use |
| `lintian` | boolean | `true` | Run lintian on the built packages |
| `revision` | string | `''` | Release mode: revision N. Leave empty for check mode. |
| `upstream-version` | string | `''` | Release mode: upstream version |
| `package-name` | string | `''` | Release mode: Debian package name used in the changelog and default rename |
| `apt-distro` | string | `''` | Release mode: APT distribution for the package name suffix (e.g. `trixie`, `any`) |
| `apt-component` | string | `''` | Release mode: APT component for the package name suffix (e.g. `main`, `hatlabs`) |
| `maintainer-name` | string | `''` | Release mode: maintainer name for `debian/changelog` |
| `maintainer-email` | string | `''` | Release mode: maintainer email for `debian/changelog` |

| Output | Description |
|---|---|
| `artifact` | Release mode: name of the uploaded package artifact. Empty in check mode. |

Repositories with several packages, architecture-specific packages or a non-standard layout replace the changelog and rename steps with [local scripts](#local-script-overrides).

### release-version.yml

Reads the upstream version from `VERSION` and computes the revision N for the commit being released. N is one more than the highest N over existing `v<upstream>+N` and `v<upstream>+N_pre` tags, or 1 when none exist. When the commit already carries a `_pre` tag, the run reuses that N, so a rerun completes the same release.

The run fails when:

- the ref is not the default branch;
- `VERSION` does not hold a version such as `1.2.3`;
- a newer commit is already released, for example when an old main run is rerun.

The caller's `main.yml` must set a `concurrency` group with `cancel-in-progress: false`. Otherwise two concurrent runs compute the same N, and `stage-release.yml` fails the second.

| Input | Type | Default | Description |
|---|---|---|---|
| `version-file` | string | `VERSION` | Path to the VERSION file |
| `runs-on` | string | `ubuntu-latest` | Runner to use |

| Output | Description |
|---|---|
| `upstream-version` | Upstream version from the VERSION file, without a `v` prefix |
| `revision` | Revision number N for this commit |
| `debian-version` | `<upstream>-<N>` |
| `prerelease-tag` | `v<upstream>+<N>_pre` |
| `stable-tag` | `v<upstream>+<N>` |

### stage-release.yml

Creates `prerelease-tag` as a published pre-release and `stable-tag` as a draft, both tagging the commit the run built, and deletes every other draft release in the repository. Publishing the draft starts the caller's `release.yml`.

With `artifact`, the packages from `build-deb.yml` are attached to both releases, and the run fails if the artifact holds no `.deb`. Without it, the releases carry notes only.

A rerun for the same commit keeps a complete existing release and replaces an incomplete one. The run fails when a release with a higher version already exists, or when a release with these tags belongs to another commit.

The release notes list the commit subjects since the last stable release. When packages are attached and `apt-repository` is set, the notes add installation instructions that link to the APT host. The host is the repository name, so `halos-org/apt.halos.fi` links to `https://apt.halos.fi`.

The calling job needs `permissions: contents: write`.

| Input | Type | Default | Description |
|---|---|---|---|
| `package-name` | string | required | Package name shown in the release notes |
| `package-description` | string | `''` | Short description for the stable release notes |
| `debian-version` | string | required | `<upstream>-<N>`, from `release-version.yml` |
| `prerelease-tag` | string | required | `v<upstream>+<N>_pre`, from `release-version.yml` |
| `stable-tag` | string | required | `v<upstream>+<N>`, from `release-version.yml` |
| `artifact` | string | `''` | Artifact with `.deb` packages to attach, from `build-deb.yml`. Empty for notes-only releases. |
| `apt-repository` | string | `''` | APT repository (owner/name, named after its host) mentioned in the notes when packages are attached |
| `apt-distro` | string | `''` | APT distribution mentioned in the notes |
| `apt-component` | string | `''` | APT component mentioned in the notes |
| `runs-on` | string | `ubuntu-latest` | Runner to use |

### apt-publish.yml

Sends a `package-updated` repository dispatch to the APT repository, which then fetches the `.deb` assets from this repository's release.

- `channel: unstable` is called from `main.yml` after `stage-release.yml`, with its `prerelease-tag`.
- `channel: stable` is called from `release.yml` on `release: published`. The job skips pre-releases and requires a `v<upstream>+<N>` tag.

On both channels the run fails when the release has no assets, so a notes-only release is never dispatched. There is no default APT repository: hatlabs callers pass `hatlabs/apt.hatlabs.fi`, halos-org callers pass `halos-org/apt.halos.fi`.

| Input | Type | Default | Description |
|---|---|---|---|
| `channel` | string | required | `unstable` or `stable` |
| `apt-repository` | string | required | APT repository to dispatch to (e.g. `halos-org/apt.halos.fi`) |
| `apt-distro` | string | required | APT distribution (e.g. `trixie`, `any`) |
| `apt-component` | string | required | APT component (e.g. `main`, `hatlabs`) |
| `prerelease-tag` | string | `''` | Unstable channel: the pre-release tag from `release-version.yml` |
| `runs-on` | string | `ubuntu-latest` | Runner to use |

| Secret | Required | Description |
|---|---|---|
| `APT_REPO_PAT` | yes | Token allowed to send `repository_dispatch` to `apt-repository` |

### publish-npm.yml

Publishes the npm package for a published stable release. Call it from `release.yml` on `release: published`; pre-releases are skipped.

Before building, the run requires that the release commit is on the default branch, the tag is `v<upstream>+<N>`, `<upstream>` equals `VERSION` at that commit, and `VERSION` equals the `version` in `package.json`. When that version is already on npm, the run skips with a warning.

The build job installs dependencies with `--ignore-scripts` (`npm ci` when `package-lock.json` exists), runs the package's `prepublishOnly` script, and packs the tarball. A separate publish job with `id-token: write` publishes that tarball with `--ignore-scripts`, so no dependency code runs next to the publish credentials.

Publication uses npm trusted publishing:

- The package's trusted publisher on npmjs.com names the caller's workflow file, `release.yml`, not this one.
- The calling job grants `permissions: contents: read` and `id-token: write`.
- The run needs a GitHub-hosted runner.
- npm adds provenance only for public repositories.

The publish job uses the concurrency group `<repository>-publish-npm-job`. A caller must not use that group name, or the run deadlocks.

| Input | Type | Default | Description |
|---|---|---|---|
| `version-file` | string | `VERSION` | Path to the VERSION file |
| `runs-on` | string | `ubuntu-latest` | GitHub-hosted runner to use; npm trusted publishing does not support self-hosted runners |

### version-bump-check.yml

Called by `checks.yml`; a caller can also call it on its own. It requires a version bump when a pull request changes files that end up in a package:

- A change under `apps/<name>/` requires the pull request to change that app's `metadata.yaml` too, where the `version` bump goes. The check does not read the version itself.
- A package-affecting change requires `VERSION` to differ from the latest stable release, once per release cycle.

Documentation, tests, CI configuration, tooling and lockfiles do not count as package-affecting. The workflow file holds the exact list.

| Input | Type | Default | Description |
|---|---|---|---|
| `runs-on` | string | `ubuntu-latest` | Runner to use |

### check-image-updates.yml

For container app repositories. Finds container images in compose files that have a newer version, and opens or updates a pull request with the new versions. The scripts it runs come from the same revision of this repository as the workflow.

| Input | Type | Default | Description |
|---|---|---|---|
| `compose-pattern` | string | required | Glob for compose files (e.g., `docker-compose.yml`) |
| `branch-name` | string | `chore/update-container-images` | PR branch name |
| `dry-run` | boolean | `false` | Log updates without creating a PR |

| Secret | Required | Description |
|---|---|---|
| `token` | no | PAT or App token for PR creation (to trigger CI on the PR). Falls back to `github.token` if not provided, but PRs from `github.token` will not trigger other workflows. |

The calling job needs `permissions: contents: write` and `pull-requests: write`.

### translation-status.yml

For translated documentation repositories, not packages. Reports which translations are behind their English source, posts that report as a pull request comment, builds the site, checks its anchors, and fails the run when any translation is stale, missing, unstamped or orphaned.

Copy the caller from `examples/docs-repo/.github/workflows/translation-status.yml`. The stanza that selects this workflow is:

```yaml
# The called workflow inherits this token. Omit pull-requests: write and the
# run still gates; only the comment is skipped.
permissions:
  contents: read
  pull-requests: write

jobs:
  translation-status:
    uses: halos-org/shared-workflows/.github/workflows/translation-status.yml@v1
```

| Input | Type | Default | Description |
|---|---|---|---|
| `runs-on` | string | `ubuntu-latest` | Runner to use |

**Requirements.** None of these is validated, so getting one wrong shows up as a failing step rather than a clear message:

- `pyproject.toml` pins [halos-docs-tools](https://github.com/halos-org/docs-tools) to a tag, and `uv.lock` is committed. The workflow runs `uv sync --locked`, so the two must agree.
- `mkdocs` and `mkdocs-static-i18n` are project dependencies. The package brings the checkers, not mkdocs.
- `mkdocs.yml` configures `mkdocs-static-i18n` with a `docs/<locale>/` tree, and leaves `site_dir` at its default. The anchor check reads `site`.
- The caller grants `pull-requests: write` if it wants the comment.

**What it enforces.** Every translation carries the git blob hash of the English page it was written against. The checker compares hashes; it cannot read the translated text. A commit that only rewrites the stamp therefore turns the gate green and makes that page's staleness permanently invisible. The bot comment prints the hash needed to do it, because an honest update needs the same hash. Catching a stamp-only diff is a reviewer's job.

**Making it a gate.** The example's `status` job carries the required check, as described in [Required status check](#required-status-check). The example deliberately carries no `paths` filter, because a required check that never runs on a PR touching none of the filtered paths leaves that PR unmergeable forever. The gate reads the repository as it stood when the run started, so two independently green PRs can merge into a stale `main`. Require branches to be up to date before merging, or use a merge queue, which needs a `merge_group` trigger the example does not have.

The checkers come from the package, so the same commands run on a laptop before you push. Glossaries and per-language rules stay in the documentation repository.

This workflow builds and runs pull request code, including code from forks, so callers should leave it on GitHub-hosted runners and must not switch the trigger to `pull_request_target`.

A repository without translations has no use for this workflow, because the status checker needs the i18n configuration to know what to compare. Such a repository consumes the package directly from its own build job instead, for example to run `check-anchors` on the built site.

## Repository requirements

Every caller of `checks.yml`:

- **`.github/actions/run-tests/action.yml`**, a composite action that runs the tests:

  ```yaml
  name: 'Run Tests'
  description: 'Run all tests'
  runs:
    using: 'composite'
    steps:
      - name: Run tests
        run: ./run test
        shell: bash
  ```

- **`.github/actions/check-versions/action.yml`**, optional, for version consistency checks.

Every caller of `release-version.yml`:

- **`VERSION`** holding the upstream version, such as `0.2.0`, without a `v` prefix.

Debian package repositories also need:

- **`.github/actions/build-deb/action.yml`**, a composite action that writes the `.deb` files to the repository root or `build/`:

  ```yaml
  name: 'Build Debian Package'
  description: 'Build .deb package'
  runs:
    using: 'composite'
    steps:
      - name: Build
        run: dpkg-buildpackage -us -uc -b && mv ../*.deb .
        shell: bash
  ```

- **`debian/`** with standard packaging files. In release mode `build-deb.yml` overwrites `debian/changelog`.
- **Repository secret `APT_REPO_PAT`**, a token allowed to send `repository_dispatch` to the APT repository.

npm package repositories also need:

- **`package.json`** whose `version` equals `VERSION`.
- **A trusted publisher** for the package on npmjs.com that names this repository and the workflow file `release.yml`.

## Version management

- **`VERSION`** holds the upstream version, for example `0.2.0`.
- **Git tags** are `v<upstream>+<N>` for stable releases and `v<upstream>+<N>_pre` for pre-releases.
- **The Debian version** is `<upstream>-<N>`.

```
Merge to main (VERSION=0.2.0, first time):
  → v0.2.0+1_pre (pre-release)
  → v0.2.0+1 (draft)

Merge to main again (same VERSION):
  → v0.2.0+2_pre (pre-release)
  → v0.2.0+2 (draft; replaces the v0.2.0+1 draft)

Bump VERSION to 0.3.0, merge to main:
  → v0.3.0+1_pre (pre-release)
  → v0.3.0+1 (draft)
```

## Local script overrides

Repositories with several packages or a non-standard layout can provide scripts that replace a default step. Each script runs from the repository root.

| Script | Replaces | Called by | Arguments |
|---|---|---|---|
| `.github/scripts/generate-changelog.sh` | `debian/changelog` generation | `build-deb.yml`, release mode | `--upstream <version> --revision <N>` |
| `.github/scripts/rename-packages.sh` | package rename | `build-deb.yml`, release mode | `--version <debian-version> --distro <distro> --component <component>` |
| `.github/scripts/generate-release-notes.sh` | release notes | `stage-release.yml` | `<debian-version> <tag> prerelease\|draft`; writes `release_notes.md` |

Example `rename-packages.sh` for a repository with two packages:

```bash
#!/bin/bash
set -euo pipefail
while [ $# -gt 0 ]; do
  case $1 in
    --version) VERSION=$2 ;;
    --distro) DISTRO=$2 ;;
    --component) COMPONENT=$2 ;;
  esac
  shift 2
done
for pkg in halos halos-marine; do
  mv "${pkg}_${VERSION}_all.deb" "${pkg}_${VERSION}_all+${DISTRO}+${COMPONENT}.deb"
done
```

## Migrating from `@main`

A caller of the legacy workflows migrates in one pull request:

1. Replace `pr.yml`, `main.yml` and `release.yml` with the example for the repository kind, and carry the repository's values over with the tables below.
2. A hatlabs repository that called `hatlabs/shared-workflows` now calls `halos-org/shared-workflows` and passes `apt-repository: hatlabs/apt.hatlabs.fi` explicitly.
3. Keep existing local actions and `.github/scripts/` overrides; their contracts are unchanged.
4. When the pull request is green, change branch protection to require `status` instead of the old check names, and merge. An open pull request gets a `status` check at its next push or rebase.
5. Watch the first main run through `apt-publish`, or through `stage-release` for npm and tag-only repositories. The migration pull request never runs `main.yml`, because `release-version.yml` refuses other branches. If the run fails, fix forward; a rerun for the same commit resumes the release.
6. Check the first published draft's APT stable dispatch or npm publish; that run is the first of the new `release.yml`.

The workflow files do not end up in a package, so the migration needs no `VERSION` bump.

### pr-checks.yml

| Legacy input | v1 |
|---|---|
| `runs-on` | `runs-on` on `checks.yml` and `build-deb.yml`. The legacy lintian job ignored it and ran on `ubuntu-latest`. |
| `skip-lintian: true` | do not call `build-deb.yml`; the legacy job skipped the whole PR build. For a PR build without lintian, call it with `lintian: false`. |
| no `.github/actions/build-deb` (lintian skipped itself) | do not call `build-deb.yml` |

Legacy lintian checked only `*.deb` in the repository root. `build-deb.yml` also checks `build/`, so a repository that builds there is linted for the first time; fix or override the findings in the migration pull request.

### build-release.yml

| Legacy input | v1 |
|---|---|
| `package-name` | `package-name` on `build-deb.yml` and `stage-release.yml` |
| `package-description` (default `Debian package`) | `package-description` on `stage-release.yml` (default empty) |
| `apt-distro`, `apt-component` | same inputs on `build-deb.yml`, `stage-release.yml` and `apt-publish.yml` |
| `apt-repository` (default `halos-org/apt.halos.fi`) | `apt-repository` on `stage-release.yml` and `apt-publish.yml`; required on `apt-publish.yml` |
| `version-file` | `version-file` on `release-version.yml`, and on `publish-npm.yml` for npm packages |
| `maintainer-name`, `maintainer-email` (defaults `Hat Labs`, `info@hatlabs.fi`) | same inputs on `build-deb.yml`, with no defaults. A caller that relied on the legacy defaults now passes values. |
| `runs-on` | `runs-on` on each called workflow |
| `skip-tests: true` | omit the `tests` job and the `needs: tests` in `main.yml` |
| `build-deb: false` | do not call `build-deb.yml` or `apt-publish.yml` |
| `run-lintian: false` | `lintian: false` on `build-deb.yml` |
| secret `APT_REPO_PAT` | secret `APT_REPO_PAT` on `apt-publish.yml` |

### publish-stable.yml

| Legacy input | v1 |
|---|---|
| `apt-distro`, `apt-component`, `apt-repository` | same inputs on `apt-publish.yml` with `channel: stable` |
| `version-pattern` | removed; the tag must be `v<upstream>+<N>` |
| secret `APT_REPO_PAT` | secret `APT_REPO_PAT` on `apt-publish.yml` |

### Repository-local npm release workflows

An npm repository with its own `release.yml` replaces its jobs with a call to `publish-npm.yml`, as in the npm example. The file name stays `release.yml`, so the package's trusted publisher needs no change. The workflow reads the package name from `package.json`.

### Other workflows

Callers of `version-bump-check.yml`, `check-image-updates.yml` and `translation-status.yml` change the ref from `@main` to `@v1`. Callers of `hatlabs/shared-workflows` also change the owner to `halos-org`.

## Legacy workflows

`pr-checks.yml`, `build-release.yml` and `publish-stable.yml` serve callers that still reference `@main`. They are frozen and are not part of the `v1` interface. They are deleted once the last `@main` caller has migrated, which is the one exception to shipping breaking changes as a new major. Progress: [issue 49](https://github.com/halos-org/shared-workflows/issues/49).
