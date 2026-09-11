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
`ordchaos.key`. Push both branches when publishing:

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
    "7eb3c7727b341ac671f1b7a06054a8aacc28cb52"
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

Both workflows install the official Guix 1.5.0 binary archive after verifying
its pinned SHA-256 digest, use a pinned and verified revision of Guix's official
foreign-distribution installer, and start its systemd daemon. The bootstrap also
loads the AppArmor profile needed for Guix user namespaces on Ubuntu 24.04. It
deliberately skips `guix pull`, so bootstrap does not compile an arbitrary Guix
revision when substitutes are unavailable. The complete release validation
still builds the provider packages and toolchains through the Guix daemon.

`.github/workflows/update-manifests.yml` runs every day at 05:23 UTC and can
also be started manually. It downloads stable and nightly from the official Rust
distribution server, verifies their `.sha256` files, publishes changed snapshots
to the working tree, and runs the complete release validation. If validation
passes, it creates an OpenPGP-signed commit, authenticates the complete channel
history, and fast-forwards `master`. If upstream has not changed, it creates no
commit. Stable/beta version rollbacks and nightly date rollbacks are rejected.

In the GitHub repository settings, open **Actions > General > Workflow
permissions** and select **Read and write permissions**. Add the armored private
key and passphrase for fingerprint
`5A5F539FD271C277ACC197CDD17FBF2AA776E8E4` as the
`AUTOMATION_GPG_PRIVATE_KEY` and `AUTOMATION_GPG_PASSPHRASE` repository secrets.
This dedicated key is authorized in `.guix-authorizations`; its public key is
stored as `automation.key` on the orphan `keyring` branch.

The workflow refuses changes outside `manifests/index.scm` and
`manifests/snapshots/*.toml`. Before pushing, it fetches `master` again and
aborts if another commit landed during validation. The `GITHUB_TOKEN` push does
not trigger another workflow run, so the complete release validation is run
before creating the signed commit.

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
