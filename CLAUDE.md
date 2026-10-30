# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Bash and Python scripts that build Debian/Ubuntu SD-card and eMMC images for the
Banana Pi BPI-R4 Pro 8X, R4 Pro 4E and BPI-R4. They use frank-w's u-boot and
kernel and a Kconfig front end. README.md is the full user manual (options,
output files, flashing, how it works). ROADMAP.md holds planned work.

## Commands

```sh
make deps                     # sudo apt-get install the build host's packages (DEPS in the Makefile)
make r4pro-8x_defconfig       # .config from configs/<name>_defconfig
make menuconfig               # edit .config (python3-kconfiglib)
make savedefconfig            # minimal ./defconfig, to copy into configs/
make                          # ./build.sh --config .config; FLAGS="--clean" etc.
make kernel                   # just the kernel, when Kernel build = source
make kernel-install HOST=root@bpi        # build the kernel, install it on a running board over SSH
scripts/check-image out/<image>.img.gz   # verify a built image offline, without root
```

There is no test suite. Cheap checks that need no sudo or network:
- `scripts/resolve-config --config configs/<name>_defconfig >/dev/null` for each
  defconfig. This catches Kconfig errors, undefined symbols in a config,
  impossible flag combinations and bad free-text values.
- `bash -n` on the shell scripts. shellcheck isn't clean today (SC2154 from the
  eval'd `CONFIG_*`, among others), so compare its warnings before and after a
  change instead of aiming for zero.
- `scripts/check-image` on an existing image in `out/`, after changing it or
  `scripts/mkimage`.

A full build runs `sudo -v` up front and keeps sudo alive for about 10 minutes,
so it needs the user's terminal: ask them to run it rather than starting it yourself.
`build.sh` takes a lock in `.cache/`, so only one build runs at a time.

## Architecture

The pipeline is `build.sh` → `scripts/resolve-config` → `scripts/rootfs` →
`scripts/fetch` (or `scripts/kernel`) → `scripts/mkimage`. README's "How it
works" section walks through each step.

The scripts talk to each other through shell assignments. Each helper prints
`NAME=value` lines on stdout, sends progress to stderr, and the caller `eval`s
the result:
- `resolve-config` prints every Kconfig symbol as `CONFIG_<NAME>`. Bools come out
  as `y` or empty, and symbols with unmet dependencies come out empty, so
  `set -u` scripts can test any of them. Test bools with `[[ -n $CONFIG_X ]]` or
  `[[ -z ... ]]`, not `== y`. It also prints `config_source` and
  `PACKAGE_OPTIONS`.
- `fetch` and `kernel` print the download and kernel variables (`UBOOT_IMG`,
  `KERNEL_TAR`, `KERNEL_VERSION`, …).
- `build.sh` exports all `CONFIG_*`, plus the values it derives (`PACKAGES`,
  `OVERLAYS`, `UENV`, `DT_OVERLAYS`, `WAN_MATCH`), to `scripts/mkimage`.
  mkimage refuses to run on its own.

Per-board logic (u-boot variant, uEnv.txt lines, device tree overlays, rootfs
overlays, WAN match) is the `case "$board"` in `build.sh`. The rest of the
image (packages, generated network/Wi-Fi files, first-boot units) is written by
`scripts/mkimage`. `overlays/<name>/` trees are copied verbatim, in the order
`build.sh` builds `OVERLAYS`. A file that depends on config values is generated
in mkimage, not kept as an overlay.

`scripts/check-image` re-resolves the image's saved `.config` and checks the
image's partitions (debugfs, mtools) against it. It mirrors what mkimage writes,
so an option that changes the image usually needs a matching check there.

## Conventions and gotchas

- **Kconfig is the single source of options.** A new option is a Kconfig symbol
  with a help text, used as `$CONFIG_<NAME>` in build.sh or mkimage. Free text
  that lands in a file or command line also gets a regex in resolve-config's
  `formats` map (or a custom check below it).
- **Undefined symbols in a config are a hard error**, so a typo can't quietly
  build something else. To remove an option, add its name to `retired` in
  resolve-config so older configs still load.
- **Package options:** each `PKG_*` prompt must start with `<debian-package>: `.
  resolve-config parses the package name from the prompt, so a new package is a
  single Kconfig entry. Every package must install on all four distros (or be
  hidden where it's missing), and all options together must still co-install.
  README's Packages section says how this was checked.
- **New board:** Kconfig's Board choice and `BOARD` default, the
  `board_defconfig` and `choices` maps in resolve-config, the `case` in
  build.sh, and a `configs/<name>_defconfig`.
- **Kernel fragments** (`kernel/*.config`) apply only to kernels built from
  source, not to frank-w's CI kernel. A fragment value the kernel's Kconfig drops
  fails the build. Patches in `kernel/patches-*` are `git format-patch` files,
  applied in name order.
- **Caches:** `.cache/rootfs/<distro>_arm64.tar.gz` is debootstrap's base system
  only, reused until `--clean`, so changes to `scripts/rootfs` need `--clean`.
  Packages and settings are applied in mkimage on every build. `.cache/apt/<distro>`
  holds the downloaded .debs (debootstrap's and apt's). `.cache/dl/api/` keeps
  GitHub API answers for 15 minutes (pinned tags indefinitely), so delete it to
  see a just-published release at once. `.cache/kernel/` holds one shallow
  bare repo (`git`, with `refs/fetched/*` kept so fetches stay incremental),
  a work tree per branch (`src-<branch>`) and the out-of-tree builds
  (`build-<branch>`).
- **Secrets:** never put a root password or Wi-Fi passphrase in `configs/`. The
  `ROOT_PASSWORD` and `WIFI_PASSPHRASE` environment variables override the
  config. `root_authorized_keys` is gitignored and belongs to the user.
- **Docs travel with the code.** Each script opens with a detailed header
  comment of its behaviour and usage. build.sh's `usage` and the Makefile's
  `help` print fixed line ranges of their headers, so fix the ranges when a
  header grows or shrinks. Kconfig help texts and README's tables (options,
  packages, overlays, check-image checks) describe the same behaviour. Update all
  of them when you change it.
- **Style:** tabs in shell, 4 spaces in Python. Comments and README use short,
  plain sentences. Commit messages have a one-line subject and a body that
  explains why.
