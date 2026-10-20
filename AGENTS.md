# shared-workflows - Agent Context

**Document Purpose**: Context for AI assistants working in this repository.

## What this is

Reusable GitHub Actions workflows (`on: workflow_call`) for halos-org and hatlabs repositories: PR checks, Debian package builds and releases, APT dispatch, container image update checks, and documentation translation gates. Scripts the workflows run live in `scripts/`.

Consumers are other repositories. Nothing here runs on its own except `ci.yml` and `move-major-tag.yml`.

## The interface

A caller depends on:

- workflow filenames under `.github/workflows/`
- `workflow_call` inputs, secrets, and outputs
- the repo-local actions a caller provides: `.github/actions/run-tests`, `build-deb` for Debian packages, and the optional `check-versions`
- the arguments passed to optional `.github/scripts/` overrides, and the files they must write
- the permissions a calling job must grant
- the `concurrency` group with `cancel-in-progress: false` that a caller's `main.yml` must set, because `release-version.yml` computes the revision from existing tags
- the `VERSION` file and the `v<upstream>+<N>` and `v<upstream>+<N>_pre` tag formats

Changing any of these incompatibly is a breaking change and ships as a new major version.

Job names inside a reusable workflow are **not** part of the interface. A call reports as `<caller job> / <called job>`, so callers put a `status` job of their own in front of branch protection and require only that. See `examples/docs-repo/.github/workflows/translation-status.yml`.

## Versioning and releases

- Releases are `vX.Y.Z`, created by hand as GitHub releases. Release candidates are `vX.Y.Z-rc.N`, published as pre-releases.
- `move-major-tag.yml` points `vX` at a newly published full release when it is the highest `vX.*.*` release. Pre-releases never move it.
- Callers pin `@vX`. Canary callers may pin an rc or a full version.
- Never delete a published tag, rc tags included; a caller may still pin it.

## Legacy workflows

`build-release.yml`, `pr-checks.yml` and `publish-stable.yml` serve callers that still reference `@main`. They are frozen: do not edit them. They are not part of the v1 interface, and their removal after the last `@main` caller migrates is the one documented exception to "breaking changes need a new major". Tracking: https://github.com/halos-org/shared-workflows/issues/49

## Checks

`ci.yml` runs actionlint over workflows and examples, shellcheck over `scripts/` and `tests/`, and every `tests/*.test.sh`. Shellcheck findings below warning severity are not reported inside workflows. Branch protection requires its `status` job.

Reusable workflows cannot be exercised from this repository. Verify a change by pointing a caller's PR at the branch or an rc tag and reading that run.

## Local rules

- Do not write internal hostnames, addresses or network details into this public repository.
- Hat Labs-specific behaviour belongs in callers' inputs, not in defaults here.
