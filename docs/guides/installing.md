# Installing Punch

Applies to Punch 0.1.

Before you can create an app, you need two things on your machine: the `punch` tool and the Crystal compiler that Punch is built for. This guide installs both from a Punch release and checks the result. It takes a few minutes, most of it downloading.

After reading this guide, you will know:

- how to download the `punch` tool, check it against the release's checksums, and put it on your `PATH`;
- how to install the Crystal release Punch needs, and why it is pinned;
- how to check the install with `punch version` and `punch db`;
- how to build the tool from source where no release fits;
- why an app's databases must be on local disk, and how to point `PUNCH_STORAGE` there.

Before you start: [Introduction: What Punch Is](introduction.md), so you know what you are installing. You need Linux (x86-64 or ARM64) or macOS, Git, and a terminal.

## What you need on the machine

Punch apps compile to native code, so the machine that builds them needs a C toolchain as well as Crystal:

- **A C compiler and linker** (`cc`). Crystal links through it, and Punch compiles its own copy of SQLite with it.
- **The development files of OpenSSL, LibYAML, and zlib.** On Debian and Ubuntu, install `build-essential libssl-dev libyaml-dev zlib1g-dev`. On macOS, install `openssl@3` and `libyaml` with Homebrew; the [Crystal install page](https://crystal-lang.org/install/) lists the packages for other systems.
- **Git**, which `shards` uses to fetch dependencies and `punch new` uses to make an app's first commit. Set `user.name` and `user.email` before you create an app; without them, the first commit fails.
- **curl**, to download the tool, and later the tool of another Punch version.

You do not install SQLite. Punch carries its own, built with Punch's options, and links it into every binary.

## Getting the `punch` tool

The `punch` tool creates apps, generates code, runs the development server, and runs the checks. Each [release of Punch](https://github.com/punchframework/punch/releases) carries it as an archive per platform: `linux-x86_64`, `linux-aarch64` (both static binaries that run on any distribution), and `macos-aarch64` (Apple silicon). Download yours and the release's checksums:

```console
$ version=0.1.0 platform=linux-x86_64
$ curl -fLO https://github.com/punchframework/punch/releases/download/v$version/punch-$version-$platform.tar.gz
$ curl -fLO https://github.com/punchframework/punch/releases/download/v$version/SHA256SUMS
```

Check the archive before you unpack it. On macOS, use `shasum -a 256 --check` in place of `sha256sum --check`:

```console
$ grep " punch-$version-$platform.tar.gz$" SHA256SUMS | sha256sum --check
punch-0.1.0-linux-x86_64.tar.gz: OK
```

The checksum shows that the archive is the one the release lists. With the GitHub CLI, `gh attestation verify punch-$version-$platform.tar.gz --repo punchframework/punch` also shows that Punch's release workflow built it.

Unpack it to a lasting place and put it on your `PATH`:

```console
$ mkdir -p ~/.local/share/punch
$ tar -xzf punch-$version-$platform.tar.gz -C ~/.local/share/punch
$ export PATH="$HOME/.local/share/punch/punch-$version-$platform:$PATH"
```

Add the `export` line to your shell's profile so new terminals find it. Besides `punch`, the directory holds `LICENSE`, `THIRD_PARTY_NOTICES.txt` (the licenses of what is built into the binary), and the installer for the compiler.

Apps created with this tool depend on that release of Punch, and `shards install` fetches its source into the app's `lib/punch`. An app on another version needs that version's tool: `punch tool:install` in the app installs it, and every `punch` you run there uses it from then on ([Tooling](../tooling.md#getting-the-tool)).

## Installing the Crystal compiler

Punch is built for one Crystal release, named in `toolchain.env` with the SHA-256 of each of its archives:

```text
CRYSTAL_VERSION=1.22.0
CRYSTAL_SHA256_LINUX_X86_64=0ddf1bab1b4bc6659845b44a87da8bff4b49e9ffd82a30acaf6ab7cd57c05048
CRYSTAL_SHA256_LINUX_AARCH64=10c18d84e833c78775f3ee8f834913ba89bd779d3849a9cf0912a434b42ddd62
CRYSTAL_SHA256_DARWIN_UNIVERSAL=995677bce3422ed979a40b9e6b6260cc544cbbbf1732fd22d9843ea0879d70f4
```

It is pinned because Punch needs the AES-GCM tag accessors that 1.22 added, and because one compiler for every machine and CI keeps builds and their errors the same everywhere. Install exactly this release. The script in the tool's directory downloads it from Crystal's releases into `~/.cache/punch-toolchain/`, unpacks it only when its SHA-256 is the one pinned, and prints the line that puts it on your `PATH`:

```console
$ cd ~/.local/share/punch/punch-$version-$platform
$ scripts/setup-toolchain.sh
export PATH="/home/you/.cache/punch-toolchain/crystal-1.22.0/bin:$PATH"
$ eval "$(scripts/setup-toolchain.sh)"
$ crystal --version
Crystal 1.22.0 [39f3f4d08] (2026-10-12)
...
```

Add the `export` line to your shell's profile as well. `PUNCH_TOOLCHAIN_DIR` changes where the script installs it.

A Crystal you installed another way works too, as long as `crystal --version` says 1.22.0. Leave `CRYSTAL_PATH` unset, so the compiler uses its own standard library.

## Checking the install

`punch version` names the Punch version, the compiler it was built with, and the SQLite and OpenSSL inside it:

```console
$ punch version
punch 0.1.0 (Crystal 1.22.0, SQLite 3.54.1, OpenSSL 3.5.9)
```

`punch db` shows the SQLite linked into the tool, its compile options, and the collations Punch adds:

```console
$ punch db
SQLite 3.54.1 (2026-10-16 14:45:20 555e07ef33f69a0957d24d8e555b702464a131d6f1607f4c3c1e4551e8e6ca76)
Compile options: ATOMIC_INTRINSICS=1 ...
Collations: de en es fr it nl pt (punch-latin-1/unicode-17.0.0)
```

`punch help` lists every command. When these three answer, the install works.

## Building the tool from source

Where no release archive fits, such as a Mac with an Intel processor, or to work on Punch itself, build the tool from a checkout. Install Crystal with `scripts/setup-toolchain.sh` from the checkout, then:

```console
$ git clone https://github.com/punchframework/punch.git ~/src/punch
$ cd ~/src/punch
$ shards install
$ crystal build src/cli/main.cr -o bin/punch --release
$ export PATH="$HOME/src/punch/bin:$PATH"
```

The first build also compiles SQLite (about 20 seconds) into `build/sqlite/`; the release build takes a minute or two. A tool built this way makes new apps depend on the checkout by path rather than on a release, so keep the checkout in one place.

## Databases on local disk

A Punch app keeps its data in four SQLite files in one directory, its storage: `primary.db`, `cache.db`, `queue.db`, and `ops.db` ([SQLite in Punch](sqlite-in-punch.md)). SQLite's write-ahead log relies on file locks that network and shared filesystems do not honour, so a database there can be corrupted without any error. Punch checks the filesystem when it opens a database and refuses one of those:

```text
/work/roster/storage is on fuse, a shared or virtual filesystem where SQLite's WAL snapshots are not reliable. Put the database on local disk (lib/punch/docs/persistence.md).
```

The storage directory is `storage/` in the app unless `PUNCH_STORAGE` says otherwise. Keep the app on local disk, or point `PUNCH_STORAGE` at a directory that is:

```console
$ PUNCH_STORAGE=$HOME/storage/roster punch dev
```

This matters most in containers and virtual machines. A project folder shared from the host, such as a Docker bind mount on macOS or a VM's shared folder, is a virtual filesystem; a named volume or the container's own disk is local.

## Optional tools

None of these is needed to start:

- **A fast linker.** `punch dev` links with mold, lld, or gold when it finds one, which saves seconds on every rebuild. On Linux, install `mold` or `lld`.
- **Docker**, to build the static release image that `punch new` writes a `Dockerfile` for ([Deploying](deploying.md)).
- **Litestream**, for continuous backups in production. The Kamal recipe's image includes it; you need it locally only to try a restore ([Backup and Restore](backup-and-restore.md)).

## Common mistakes

**Another Crystal version on the `PATH`.** A system-wide Crystal found before the pinned one builds a tool and apps against the wrong standard library. Check `which crystal` and `crystal --version`, and put the pinned release first.

**Unpacking an archive you did not check.** Compare it with the release's `SHA256SUMS` first, as above; a download that does not match is not the release's.

**A tool built from source somewhere temporary.** `punch new` writes the checkout's path into each new app's `shard.yml`. Moving or deleting the checkout breaks every app made from it. Keep it in one place, and update it there with Git.

**No Git identity.** `punch new` stops at its last step:

```text message=src/punch/cli/tool/new.cr
punch: first commit failed in roster; the files are written. Fix it, then run:
  cd roster
  git commit --quiet -m 'New app from punch new 0.1.0'

...
```

The lines after the command are Git's own message. Set `git config --global user.name` and `user.email`, then run the command it prints. Everything before the commit is done.

**The app in a shared folder.** Creating an app inside a folder shared with a host or a VM fails when the database is first opened:

```text message=src/punch/database/filesystem.cr
/work/roster/storage is on fuse, a shared or virtual filesystem where SQLite's WAL snapshots are not reliable. Put the database on local disk (lib/punch/docs/persistence.md).
```

Create it on local disk, or set `PUNCH_STORAGE`.

## Limits

- Releases carry the tool for Linux on x86-64 and ARM64 and for macOS on Apple silicon; elsewhere, build it from source. The toolchain script supports Linux on x86-64 and ARM64, and macOS. Windows is not supported.
- There is no package for a package manager; the tool comes as a release archive.

## Rules

- Check a release archive against its `SHA256SUMS` before you unpack it. ([Getting the `punch` tool](#getting-the-punch-tool))
- Install exactly the Crystal release in `toolchain.env`. ([Installing the Crystal compiler](#installing-the-crystal-compiler))
- In an app on another Punch version, run `punch tool:install` instead of building the tool. ([Getting the `punch` tool](#getting-the-punch-tool))
- Build `punch` from source only in a checkout that stays in one place. ([Building the tool from source](#building-the-tool-from-source))
- Keep every storage directory on local disk; set `PUNCH_STORAGE` when the app is not. ([Databases on local disk](#databases-on-local-disk))

## Reference

- [Tooling: getting the tool](../tooling.md#getting-the-tool): how the tool and an app's Punch are matched.
- [Persistence: the SQLite in every binary](../persistence.md#the-sqlite-in-every-binary) and [the filesystem check](../persistence.md#filesystem-check).
- Next: [Getting Started](getting-started.md).
