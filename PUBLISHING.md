# Publishing The Channel

The channel is published by pushing this Git repository to a stable HTTPS Git
URL. Guix reads `.guix-channel` and exposes the packages under `guix/`; there is
no separate package upload step.

## Create The GitHub Repository

Create an empty GitHub repository, then add and push the remote:

```sh
git remote add origin git@github.com:OWNER/guix-rust-toolchain.git
git push -u origin master
```

Do not create a README or license on GitHub when creating the repository, since
both already exist locally.

## Authenticate The Guix Channel

This repository authorizes the following OpenPGP key in
`.guix-authorizations`:

```text
FF0F1FE0A176071F0E39A94DFF93E1DAE0897EDE
OrdChaos <orderchaos@ordchaos.com>
```

The orphan `keyring` branch contains its public key as
`ordchaos-E0897EDE.key`. Push both branches when publishing:

```sh
git push -u origin master
git push -u origin keyring
```

The authorization file has this form:

```scheme
(authorizations
 (version 0)
 (("FF0F1FE0A176071F0E39A94DFF93E1DAE0897EDE"
   (name "OrdChaos"))))
```

Use the first signed commit containing this file as the channel introduction.
Every later commit must be signed by a key authorized by the preceding commit.

Consumers can then add the channel to `~/.config/guix/channels.scm`:

```scheme
(cons*
 (channel
  (name 'guix-rust-toolchain)
  (url "https://github.com/OWNER/guix-rust-toolchain.git")
  (branch "master")
  (introduction
   (make-channel-introduction
    "SIGNED-INTRODUCTION-COMMIT"
    (openpgp-fingerprint
     "FF0F1FE0A176071F0E39A94DFF93E1DAE0897EDE"))))
 %default-channels)
```

After replacing the URL, commit, and fingerprint:

```sh
guix pull
guix install rust-toolchain-proxies
```

Test the published channel from a clean profile before announcing it:

```sh
guix time-machine -C channels.scm -- describe
guix time-machine -C channels.scm -- build rust-toolchain-proxies
```

## GitHub Actions

`.github/workflows/ci.yml` runs the complete offline and integration release
validation on pushes, pull requests, and manual dispatches.

Both workflows bootstrap from Ubuntu's Guix package and then pull the
authenticated Guix revision pinned in `.github/guix-channels.scm`. This avoids
depending on an archived third-party Guix installer action and keeps CI package
evaluation reproducible. Update that pin explicitly when adopting a newer Guix
revision.

`.github/workflows/update-manifests.yml` runs every day at 05:23 UTC and can
also be started manually. It downloads stable and nightly from the official Rust
distribution server, verifies their `.sha256` files, publishes changed snapshots
to the working tree, runs the complete release validation, and creates or updates
the `automation/update-rust-manifests` pull request. If upstream has not changed,
it creates no commit or pull request. Stable/beta version rollbacks and nightly
date rollbacks are rejected rather than proposed.

In the GitHub repository settings, open **Actions > General > Workflow
permissions**, select **Read and write permissions**, and enable **Allow GitHub
Actions to create and approve pull requests**. The workflows otherwise require
no repository secrets.

The update workflow deliberately creates a pull request instead of pushing to
`master`. Its bot commit is not part of the authenticated channel history until
a maintainer reviews the changes and merges them with an authorized OpenPGP
signature. Do not merge the unsigned bot commit into authenticated history. A
safe flow is to fetch the automation branch, create a signed squash or signed
cherry-pick commit locally, and push that signed commit to `master`. An ordinary
merge is not safe: signing only the merge commit does not authenticate its
unsigned bot parent.

GitHub-created pull requests using `GITHUB_TOKEN` may require one-time workflow
approval before the pull-request CI starts. The update workflow already runs the
same release validation before opening the pull request.

## Merge An Automated Manifest PR

The automation branch contains an unsigned bot commit. Never merge it with a
merge commit, because signing the merge does not authenticate its unsigned
parent. Use one of the following flows.

For a signed squash, replace `NUMBER` with the pull request number:

```sh
git switch master
git pull --ff-only origin master
git fetch origin pull/NUMBER/head:manifest-pr-NUMBER
git merge --squash manifest-pr-NUMBER
git diff --cached -- manifests
./scripts/validate-release.sh
git commit -SFF0F1FE0A176071F0E39A94DFF93E1DAE0897EDE \
  -m "Update bundled Rust manifests"
git verify-commit HEAD
guix git authenticate -k origin/keyring \
  --end="$(git rev-parse HEAD)" \
  SIGNED-INTRODUCTION-COMMIT \
  FF0F1FE0A176071F0E39A94DFF93E1DAE0897EDE
git push origin HEAD:master
gh pr close NUMBER --comment "Applied as signed commit $(git rev-parse HEAD)."
git branch -D manifest-pr-NUMBER
```

When the PR consists of one automation commit, signed cherry-pick is equivalent:

```sh
git switch master
git pull --ff-only origin master
git fetch origin pull/NUMBER/head:manifest-pr-NUMBER
git cherry-pick -SFF0F1FE0A176071F0E39A94DFF93E1DAE0897EDE \
  manifest-pr-NUMBER
./scripts/validate-release.sh
git verify-commit HEAD
guix git authenticate -k origin/keyring \
  --end="$(git rev-parse HEAD)" \
  SIGNED-INTRODUCTION-COMMIT \
  FF0F1FE0A176071F0E39A94DFF93E1DAE0897EDE
git push origin HEAD:master
gh pr close NUMBER --comment "Applied as signed commit $(git rev-parse HEAD)."
git branch -D manifest-pr-NUMBER
```

The squash flow validates before creating the commit. The cherry-pick flow
validates immediately after creating it; do not push if validation fails. In
either flow, inspect `git status` and `git diff` before committing or pushing.

## Release Checklist

Run the live release validation before publishing the first authenticated
revision or changing channel authorization:

```sh
./scripts/validate-release.sh --live
git diff --check
git status --short
```

Confirm that the introduction commit and every later commit authenticate before
sharing the consumer channel declaration.
