# Hat Labs Shared Workflows

Reusable GitHub Actions workflows for two classes of Hat Labs repository: those
that build Debian packages, and documentation sites.

## Overview

Most of these workflows implement a standardized release process for Debian
packages:

1. **PR** → Run tests
2. **Merge to main** → Build .deb, create pre-release, dispatch to APT unstable
3. **Publish release** → Dispatch to APT stable

`translation-status.yml` is the exception. It serves translated documentation
repositories and has nothing to do with packaging.

## Workflows

### pr-checks.yml

Runs tests and lintian checks on pull requests.

```yaml
# .github/workflows/pr.yml
name: Pull Request Checks

on:
  pull_request:
    branches: [main]

jobs:
  checks:
    uses: halos-org/shared-workflows/.github/workflows/pr-checks.yml@main
```

**Inputs:**
| Input | Default | Description |
|-------|---------|-------------|
| `runs-on` | `ubuntu-latest` | Runner to use for tests |
| `skip-lintian` | `false` | Skip lintian checks |

**Jobs:**
1. **tests**: Runs `.github/actions/run-tests/action.yml`
2. **version-check**: Runs `.github/actions/check-versions/action.yml` (if exists)
3. **lintian**: Builds package and runs lintian (if `.github/actions/build-deb/action.yml` exists)

**Version Checks:**
- Automatically runs if `.github/actions/check-versions/action.yml` exists
- Use to verify VERSION file stays in sync with language-specific version files
- Each repo implements its own version checking logic

**Lintian Checks:**
- Automatically runs if `.github/actions/build-deb/action.yml` exists
- Fails on errors and warnings
- To suppress specific tags, create `debian/<package>.lintian-overrides`
- Set `skip-lintian: true` to disable

**Required local action**: `.github/actions/run-tests/action.yml`

**Optional local actions**:
- `.github/actions/build-deb/action.yml` (enables lintian checks)
- `.github/actions/check-versions/action.yml` (enables version consistency checks)

### build-release.yml

Main branch CI/CD: test, build, release, dispatch.

```yaml
# .github/workflows/main.yml
name: Main Branch CI/CD

on:
  push:
    branches: [main]

jobs:
  build-release:
    uses: halos-org/shared-workflows/.github/workflows/build-release.yml@main
    with:
      package-name: my-package
      package-description: 'Description for release notes'
    secrets:
      APT_REPO_PAT: ${{ secrets.APT_REPO_PAT }}
```

**Inputs:**
| Input | Default | Description |
|-------|---------|-------------|
| `package-name` | *required* | Debian package name |
| `package-description` | `Debian package` | Short description |
| `apt-distro` | `trixie` | APT distribution |
| `apt-component` | `main` | APT component |
| `apt-repository` | `hatlabs/apt.hatlabs.fi` | APT repo to dispatch to |
| `version-file` | `VERSION` | Path to version file |
| `maintainer-name` | `Hat Labs` | Changelog maintainer |
| `maintainer-email` | `info@hatlabs.fi` | Changelog email |
| `skip-tests` | `false` | Skip test job |

**Required local actions** (hardcoded paths):
- `.github/actions/run-tests/action.yml` - Test action
- `.github/actions/build-deb/action.yml` - Build action

**Optional local script overrides** (for multi-package or custom repos):
- `.github/scripts/generate-changelog.sh` - Custom changelog generation
- `.github/scripts/rename-packages.sh` - Custom package renaming
- `.github/scripts/generate-release-notes.sh` - Custom release notes

If these scripts exist, they will be called instead of the default inlined logic.
See [Local Script Overrides](#local-script-overrides) for details.

**Secrets:**
| Secret | Description |
|--------|-------------|
| `APT_REPO_PAT` | PAT for dispatching to APT repository |

### publish-stable.yml

Handles stable release publishing.

```yaml
# .github/workflows/release.yml
name: Release Published

on:
  release:
    types: [published]

jobs:
  publish:
    uses: halos-org/shared-workflows/.github/workflows/publish-stable.yml@main
    secrets:
      APT_REPO_PAT: ${{ secrets.APT_REPO_PAT }}
```

**Inputs:**
| Input | Default | Description |
|-------|---------|-------------|
| `apt-distro` | `trixie` | APT distribution |
| `apt-component` | `main` | APT component |
| `apt-repository` | `hatlabs/apt.hatlabs.fi` | APT repo to dispatch to |
| `version-pattern` | `^v([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]+)$` | Tag validation regex |

### translation-status.yml

For translated documentation repositories, not Debian packages. Reports which
translations are behind their English source, posts that report as a pull
request comment, builds the site, checks its anchors, and fails the run when any
translation is stale, missing, unstamped or orphaned.

Copy the caller from `examples/docs-repo/.github/workflows/translation-status.yml`.
The stanza that selects this workflow is:

```yaml
# The called workflow inherits this token. Omit pull-requests: write and the
# run still gates; only the comment is skipped.
permissions:
  contents: read
  pull-requests: write

jobs:
  translation-status:
    uses: halos-org/shared-workflows/.github/workflows/translation-status.yml@main
```

**Inputs:**
| Input | Default | Description |
|-------|---------|-------------|
| `runs-on` | `ubuntu-latest` | Runner to use |

**Requirements** — none of these is validated, so getting one wrong shows up as
a failing step rather than a clear message:
- `pyproject.toml` pins [halos-docs-tools](https://github.com/halos-org/docs-tools)
  to a tag, and `uv.lock` is committed. The workflow runs `uv sync --locked`, so
  the two must agree.
- `mkdocs` and `mkdocs-static-i18n` are project dependencies. The package brings
  the checkers, not mkdocs.
- `mkdocs.yml` configures `mkdocs-static-i18n` with a `docs/<locale>/` tree, and
  leaves `site_dir` at its default — the anchor check reads `site`.
- The caller grants `pull-requests: write` if it wants the comment.

**What it enforces.** Every translation carries the git blob hash of the English
page it was written against. The checker compares hashes; it cannot read the
translated text. A commit that only rewrites the stamp therefore turns the gate
green and makes that page's staleness permanently invisible — and the bot
comment prints the hash needed to do it, because that is also what an honest
update needs. Catching a stamp-only diff is a reviewer's job.

**Making it a gate.** Nothing here makes the check required; that is a branch
protection rule in the consuming repository. The check is named `<your job id> /
translation-status`, which is a name a caller cannot choose freely: a
reusable-workflow call always reports as `<caller job> / <called job>`. A
repository that already requires some other context, or that would rather not
tie its protection to a job name in this repository, can carry the name on a
job of its own that depends on this one — see the caller example. Two more
things to know before enabling it: the example deliberately carries no `paths`
filter, because a required check that never runs on a PR touching none of the
filtered paths leaves that PR unmergeable forever;
and the gate reads the repository as it stood when the run started, so two
independently green PRs can merge into a stale `main`. Require branches to be up
to date before merging, or use a merge queue — which needs a `merge_group`
trigger the example does not have.

The checkers come from the package, so the same commands run on a laptop before
you push. Glossaries and per-language rules stay in the documentation
repository.

This workflow builds and runs pull request code, including code from forks, so
callers should leave it on GitHub-hosted runners and must not switch the trigger
to `pull_request_target`.

A repository without translations has no use for this workflow — the status
checker needs the i18n configuration to know what to compare. Such a repository
consumes the package directly from its own build job instead, for example to run
`check-anchors` on the built site.

`hatlabs` documentation repositories call this copy rather than the one in
`hatlabs/shared-workflows`. The one-org-per-copy rule exists to keep the APT
inputs straight, and this workflow has none; a single copy is deliberate.

## Repository Requirements (Debian package workflows)

Each repository using `pr-checks.yml`, `build-release.yml` or
`publish-stable.yml` must have the following. A documentation repository calling
`translation-status.yml` needs none of them — its requirements are listed in
that workflow's section above.

### 1. VERSION file

```
0.2.0
```

Plain version number, no `v` prefix.

### 2. Test action (`.github/actions/run-tests/action.yml`)

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

### 3. Build action (`.github/actions/build-deb/action.yml`)

```yaml
name: 'Build Debian Package'
description: 'Build .deb package'
runs:
  using: 'composite'
  steps:
    - name: Build
      run: dpkg-buildpackage -us -uc -b
      shell: bash
```

### 4. debian/ directory

Standard Debian packaging files. The `debian/changelog` will be auto-generated.

### 5. Repository secret: `APT_REPO_PAT`

Personal Access Token with permission to trigger repository dispatch on the APT repository.

## Version Management

- **VERSION file**: Contains upstream version (e.g., `0.2.0`)
- **Git tags**: Auto-generated as `v{version}+{N}` or `v{version}+{N}_pre`
- **Revision (N)**: Auto-incremented based on existing tags

### Version Progression Example

```
Push to main (VERSION=0.2.0, first time):
  → Creates v0.2.0+1_pre (pre-release)
  → Creates v0.2.0+1 (draft)

Push to main again (same VERSION):
  → Creates v0.2.0+2_pre (pre-release)
  → Creates v0.2.0+2 (draft)

Bump VERSION to 0.3.0, push to main:
  → Creates v0.3.0+1_pre (pre-release)
  → Creates v0.3.0+1 (draft)
```

## Migration Guide

To migrate an existing repository:

1. **Create local actions** if not present:
   - `.github/actions/run-tests/action.yml`
   - `.github/actions/build-deb/action.yml`

2. **Replace workflow files**:
   ```bash
   # Backup existing workflows
   mv .github/workflows/pr.yml .github/workflows/pr.yml.bak
   mv .github/workflows/main.yml .github/workflows/main.yml.bak
   mv .github/workflows/release.yml .github/workflows/release.yml.bak
   ```

3. **Copy caller templates** from `examples/` and customize.

4. **Scripts**: For simple single-package repos, you can remove old scripts (now inlined).
   For multi-package repos, keep the scripts - they'll be used as overrides.

5. **Test** with a PR before merging.

## Local Script Overrides

For repos with non-standard structures (e.g., multiple packages, subdirectories), provide local scripts that the shared workflow will call instead of the default inlined logic.

### generate-changelog.sh

Called with: `--upstream <version> --revision <N>`

Example for multi-package repo:
```bash
#!/bin/bash
# Generate changelogs for multiple packages
for pkg in halos halos-marine; do
  cat > ${pkg}/debian/changelog <<EOF
${pkg} (${UPSTREAM}-${REVISION}) unstable; urgency=medium
  * Build ${REVISION}
 -- Maintainer <email>  $(date -R)
EOF
done
```

### rename-packages.sh

Called with: `--version <debian-version> --distro <distro> --component <component>`

Example:
```bash
#!/bin/bash
# Rename multiple packages
for pkg in halos halos-marine; do
  OLD="${pkg}_${VERSION}_all.deb"
  NEW="${pkg}_${VERSION}_all+${DISTRO}+${COMPONENT}.deb"
  [ -f "$OLD" ] && mv "$OLD" "$NEW"
done
```

### generate-release-notes.sh

Called with: `<debian-version> <tag-version> <release-type>`

Where `release-type` is `prerelease` or `draft`. Must write to `release_notes.md`.

## Examples

See `examples/` directory for complete caller workflow examples.
