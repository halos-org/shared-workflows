# Hat Labs Shared Workflows

Reusable GitHub Actions workflows for the pr-main-release strategy used across Hat Labs repositories.

## Overview

These workflows implement a standardized release process:

1. **PR** → Run tests
2. **Merge to main** → Build .deb, create pre-release, dispatch to APT unstable
3. **Publish release** → Dispatch to APT stable

## Workflows

### pr-checks.yml

Runs tests on pull requests.

```yaml
# .github/workflows/pr.yml
name: Pull Request Checks

on:
  pull_request:
    branches: [main]

jobs:
  checks:
    uses: hatlabs/shared-workflows/.github/workflows/pr-checks.yml@main
```

**Inputs:**
| Input | Default | Description |
|-------|---------|-------------|
| `test-action` | `./.github/actions/run-tests` | Path to test action |
| `runs-on` | `ubuntu-latest` | Runner to use |

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
    uses: hatlabs/shared-workflows/.github/workflows/build-release.yml@main
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
| `test-action` | `./.github/actions/run-tests` | Path to test action |
| `build-action` | `./.github/actions/build-deb` | Path to build action |
| `version-file` | `VERSION` | Path to version file |
| `maintainer-name` | `Hat Labs` | Changelog maintainer |
| `maintainer-email` | `info@hatlabs.fi` | Changelog email |
| `skip-tests` | `false` | Skip test job |

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
    uses: hatlabs/shared-workflows/.github/workflows/publish-stable.yml@main
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

## Repository Requirements

Each repository using these workflows must have:

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

4. **Remove old scripts** (now inlined in shared workflows):
   - `.github/scripts/calculate-revision.sh`
   - `.github/scripts/generate-changelog.sh`
   - `.github/scripts/generate-release-notes.sh`

5. **Test** with a PR before merging.

## Examples

See `examples/` directory for complete caller workflow examples.
