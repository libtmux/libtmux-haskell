# Releasing to Hackage

Push a `v<version>` tag on a commit already merged into `master` to publish
`libtmux-haskell` and its Haddock documentation. The first release is
`0.0.1.0`, marked experimental. Review the [support and API status](../docs/status.md)
before describing the release.

The [release workflow](workflows/release.yml) runs the complete
[CI workflow](workflows/ci.yml) for the selected commit. CI checks source-archive
consumers and retains the source archive, Hackage documentation archive and
`SHA256SUMS`. Only the upload job receives the Hackage credential.

## One-time account and repository setup

1. [Register a Hackage account](https://hackage.haskell.org/users/register-request)
   and complete email verification. Request membership in the uploaders group;
   registration alone does not grant upload permission. The registration page
   explains endorsement and trustee-request options.
2. Confirm that you can upload `libtmux-haskell`. Uploading the first candidate
   for an unused package name establishes its maintainer group. If the name
   already belongs to another maintainer, resolve ownership before publishing.
3. Create an API token through
   [Hackage account management](https://hackage.haskell.org/users/account-management).
   Keep its value in your password manager and GitHub's secret store. The
   workflow uses token authentication; follow the
   [trusted-publishing proposal](https://github.com/haskell/hackage-server/issues/1443)
   for native OIDC support.
4. Create a GitHub environment named `hackage` in
   [repository environments](https://github.com/libtmux/libtmux-haskell/settings/environments).
   Restrict deployment to `master` and `v*` tags. `master` permits manual candidate
   uploads; publication additionally requires a matching tag on `master` ancestry.
   Add a required reviewer if publication needs a human approval gate.
5. Add the environment secret named `HACKAGE_AUTH_TOKEN`. This command prompts
   for the token without putting it in shell history:

```console
$ gh secret set HACKAGE_AUTH_TOKEN \
    --repo libtmux/libtmux-haskell \
    --env hackage
```

Merge the release-workflow PR before dispatching it manually. GitHub requires
the workflow to exist on the default branch before enabling manual dispatch.

## Review the initial candidate

Start a manual run from the merged default branch. `publish=false` is the
default and uploads a candidate outside the main package index:

```console
$ gh workflow run release.yml \
    --repo libtmux/libtmux-haskell \
    --ref master \
    --field publish=false
```

Open the [release runs](https://github.com/libtmux/libtmux-haskell/actions/workflows/release.yml)
and approve the `hackage` environment if configured. Review the
[initial candidate](https://hackage.haskell.org/package/libtmux-haskell-0.0.1.0/candidate)
and its documentation. The upload job compares the served source and
documentation with the checked archives, then builds and executes the pure
typed-values example from the public archive outside the checkout.

To inspect the retained files, download the `hackage-<commit>-<attempt>` artifact
from the run. It contains only the core source archive, documentation archive
and their checksums. Example packages are consumers, not published packages.

## Publish the initial version tag

Start with a clean checkout containing the merged release changes:

```console
$ git switch master
```

```console
$ git pull --ff-only origin master
```

Check that the version, tag and versioned changelog agree:

```console
$ python3 scripts/release.py check --tag v0.0.1.0
```

Create the annotated release tag:

```console
$ git tag \
    --annotate v0.0.1.0 \
    --message 'Initial experimental Hackage release'
```

Pushing this tag starts publication after CI passes:

```console
$ git push origin refs/tags/v0.0.1.0
```

Approve the environment if required. Verify that the upload job finishes its
source, documentation and external-consumer checks, then inspect the
[published package](https://hackage.haskell.org/package/libtmux-haskell-0.0.1.0)
and [versioned API documentation](https://hackage.haskell.org/package/libtmux-haskell-0.0.1.0/docs/index.html).
A green CI build or a pushed tag alone does not establish publication.

## Recover an interrupted release

Rerun failed jobs from the release run. The workflow downloads the retained
archives and validates their checksums and package identity before uploading.
If those artifacts have expired, rerun all jobs to rebuild them from the same
tag with the pinned toolchain.

If Hackage already serves identical source bytes, the helper skips the source
upload and uploads documentation again. It refuses different bytes for an
existing version. A failed documentation or consumer check can therefore leave
the source already published; inspect the package before choosing a new version.

After fixing an account or secret, an existing release tag can also be retried
manually. Publication requires `publish=true` and a tag ref:

```console
$ gh workflow run release.yml \
    --repo libtmux/libtmux-haskell \
    --ref v0.0.1.0 \
    --field publish=true
```

Keep published tags fixed. If source changes are needed, prepare a new version
and tag; Hackage source versions are permanent. See
[Hackage's upload policy](https://hackage.haskell.org/upload) and
[Cabal's upload command](https://cabal.readthedocs.io/en/3.18/cabal-commands.html#cabal-upload).

## Later releases

Update the root Cabal version and the example dependency bounds together.
Keep the installation guide's displayed package file synchronized with the
example source. Add a matching `## <version>` changelog section and retain
`## Unreleased` for subsequent work. Follow the
[Package Versioning Policy](https://pvp.haskell.org/): the first two components
together identify the major API version.

Use the same candidate review and tag procedure with the new version. Run the
[contributor checks](CONTRIBUTING.md#checks) before opening its release PR.
Hackage publication is separate from the manual shared-site documentation
deployment described in [CONTRIBUTING.md](CONTRIBUTING.md#shared-documentation).
