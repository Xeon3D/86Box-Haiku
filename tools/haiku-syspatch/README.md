# haiku-syspatch

`haiku-syspatch` runs on Haiku. It rebuilds the system package of the
**running** system with your own patches applied, and can install the result.
It was written to test the keyboard-grab prototype
([`doc/haiku-keyboard-grab.md`](../../doc/haiku-keyboard-grab.md)), but it
works with any patch that only changes files shipped in Haiku's system
packages, such as libbe, the servers or the input_server add-ons.

> Local builds only. Haiku doesn't accept AI-generated contributions (see
> its `AGENTS.md`). Neither this tool nor the prototype patch is meant to go
> upstream.

## Quick start

The script isn't packaged. Copy it to a folder on `PATH` first, or run it
by its full path:

```sh
mkdir -p ~/config/non-packaged/bin
cp haiku-syspatch ~/config/non-packaged/bin/
```

```sh
haiku-syspatch info                       # what's installed and running
haiku-syspatch doctor --install-deps      # install the build prerequisites
haiku-syspatch all -t kbgrab -p ~/86Box/doc/haiku-keyboard-grab.patch
```

`all` runs `doctor`, `fetch`, `build` and `install`. It asks before
installing.

| Command | What it does |
|---|---|
| `info` | Shows the installed `haiku` package and its version, which is split into series, base `hrev` tag, commits since the tag and local build tag. Also shows the architecture, whether a secondary architecture or `haiku_devel` is installed, and the running kernel revision (`uname -v`). Warns when an update is waiting for a reboot. |
| `doctor [--install-deps]` | Checks for git, jam, gcc, make, nasm, bison, flex, m4, makeinfo, autoconf, automake, gawk, python3 and the zstd and zlib development libraries, and checks free disk space (about 8 GiB). With `--install-deps` it installs the missing pieces with `pkgman`, which shows its plan and asks first. It deliberately does **not** need `gcc_syslibs_devel`: that package pins `gcc_syslibs`, and on a beta6 VM in November 2026 installing it upgraded the system GCC from 13.3 to 15.3. |
| `fetch` | Clones the source and checks out the exact commit the installed system was built from. |
| `build -p <patch>... [-t <tag>] [-j <jobs>]` | Applies the patches to that commit and builds the replacement packages. The output and a `MANIFEST` go in `~/haiku-syspatch/<hrev>_<n>/out/<version>/`. |
| `install [--yes] [--force] [dir]` | Backs up the official packages, shows exactly what will be replaced, asks, then runs `pkgman install`. The change takes effect after a reboot. |
| `restore [--yes]` | Reinstalls the official packages from the backup. Without a backup it runs `pkgman full-sync` against the repositories, after asking. |
| `status` | Runs `info` and also shows the manifest of the last local build. |

Environment variables:

- `HAIKU_SYSPATCH_DIR`: the work directory, `~/haiku-syspatch` by default.
- `HAIKU_SYSPATCH_JOBS`: how many build jobs to run.
- `HAIKU_GIT_MIRROR` and `HAIKU_GIT_TAGS`: alternative source URLs.

## Design

### 1. Finding the running revision

The version of the installed system package says exactly what was built:

```
haiku-r1~beta6_hrev59866_92-1-x86_64.hpkg
      └series─┘└─tag───┘└N┘ └pkg revision
```

- `hrev59866` is the last `hrev` tag before the build.
- `_92` means the build was 92 commits after that tag. This is the case on
  release branches such as `r1beta6`. A nightly built from a tag has no
  count.
- The build system writes this string from `git describe --tags
  --match=hrev*` (`build/scripts/determine_haiku_revision`), with `-` and
  `+` turned into `_` (`build/jam/PackageRules`).
- `uname -v` gives the same information for the *running* kernel, for
  example `hrev59866+92`.

The tool reads the version with `package list -i` from
`/boot/system/packages/haiku-*.hpkg`, which is how Haiku's own `configure`
finds the architecture. It compares the result with `uname -v` to spot an
update that is still waiting for a reboot.

### 2. Getting that exact source

- The source is cloned from the GitHub mirror with `--filter=blob:none`. That
  fetches all of the history but only the file contents that are actually
  checked out.
- The GitHub mirror **doesn't carry the `hrev` tags**, so the one tag that's
  needed comes from Haiku's own server (`review.haiku-os.org/haiku`).
- The tool finds the build commit as follows:
  1. A count of 0 means the commit is the tag itself.
  2. Otherwise it maps the series to branch candidates: `r1~beta6` becomes
     `r1beta6`, with `master` as the fallback.
  3. On each candidate branch that contains the tag, it walks the
     first-parent chain from the tag and takes commit number N.
  4. It accepts that commit only if `git describe` returns exactly
     `hrevX-N-g…`, which is the inverse of how the version was made.
- The commit is recorded in `base-commit`, and the tree is checked out on a
  local branch `syspatch/<hrev>_<n>`.

Example: the test VM reports `hrev59866+92`, and the tool resolved it to
`f2567c4509` on `r1beta6` (2026-10-14, the same date as `uname -v`).

### 3. Building a replacement package, not a small add-on package

The obvious idea is a small extra package that contains only the changed
files (`libbe.so`, `app_server`, …) and overrides the ones in `haiku`.
**packagefs doesn't allow that.** When two packages provide the same file,
`PackageNode::HasPrecedenceOver()`
(`src/add-ons/kernel/file_systems/packagefs/package/PackageNode.cpp`)
always prefers the package with the `system_package` flag. The `haiku`
package has that flag. Only a system package can replace system files, so the
tool rebuilds the system packages themselves:

- `haiku.hpkg`, which contains the kernel, libraries, servers and add-ons.
- `haiku_devel.hpkg`. It requires `haiku == <exact version>`, so it has to
  be rebuilt along with `haiku` whenever it's installed. It also ships the
  patched headers, so you can build apps against a new API.
- (Hybrid 32-bit systems would also need `haiku_<arch>` and
  `haiku_<arch>_devel` for the secondary architecture; see Limits.)

Other packages (`haiku_loader`, `haiku_datatranslators` and so on) only
require `haiku` with no exact version, so they stay as they are.

The build works like this:

- **Patches.** Each patch is applied on top of the base commit: `git am` for
  mbox-format patches, otherwise `git apply --3way`. The patches are
  committed locally. The tree is reset to the base commit before every
  build, so builds can be repeated.
- **Cross tools, not the native gcc.** The tool clones the branch's
  `buildtools` and runs
  `configure --cross-tools-source … --build-cross-tools x86_64`, which builds
  Haiku's own binutils and gcc on the Haiku machine. The build directory
  is reused for later builds on the same branch, so this cost is paid once.
  A native configure (no arguments, using the system gcc) looks simpler, but
  it fails on x86_64 for two reasons, both found on the beta6 VM:
  1. The `haiku` package includes the 32-bit BIOS and PXE boot loaders
     (`data/platform_loaders/`). The native gcc has no 32-bit libgcc, so the
     link fails (`undefined reference to __udivmoddi4`). The jam rule that
     builds them is defined inside `src/system/boot/Jamfile`, so a
     `UserBuildConfig` can't swap in prebuilt copies.
  2. The branch pins `gcc_syslibs_devel` to one GCC version
     (`build/jam/repositories/HaikuPorts/<arch>`; 13.3.0 on beta6), and the
     build uses that package's headers. A different native gcc breaks the
     build, for example GCC 15 with GCC 13 headers gives
     ``attribute 'target' argument 'avx512er' is unknown``.

  The cross tools come from the same branch, so they always match.
- **Environment.** In non-login shells (`ssh host command`) the tool first
  sources `/boot/system/boot/SetupEnvironment`. Without that, `LIBRARY_PATH`
  is empty, the build's host tools can't find `/boot/system/lib`, and they
  exit silently with status 3.
- **Build.** The tool runs `jam -q -j<jobs> -sHAIKU_REVISION=<hrev>+<n>+<tag>
  haiku.hpkg haiku_devel.hpkg`. The first run on a branch includes the
  cross tools; later builds are incremental and only rebuild what the
  patches touch.

### 4. Versioning

The tool overrides the build revision with `HAIKU_REVISION`, a jam variable
that the build system already supports. The value is
`hrev59866+92+<tag>`, so the packages are versioned
`r1~beta6_hrev59866_92_<tag>-1`. The tag is limited to `[a-z0-9]`, which
keeps the version valid. Haiku compares versions naturally, so:

| Comparison | Result |
|---|---|
| `…_92_kbgrab` vs official `…_92` | Local build is newer. pkgman installs it as an update, and `pkgman update` won't quietly swap it back. |
| `…_92_kbgrab` vs official `…_93` | Official is newer. A normal system update replaces the patched build, which is the safe default. Run `haiku-syspatch all` again after updating. |

`uname -v` and AboutSystem show `hrev59866+92+kbgrab`, so a patched system
is easy to recognize.

### 5. Installing safely

- The official `haiku*.hpkg` files are copied to `~/haiku-syspatch/backup/`
  first, so `restore` works offline.
- Packages are only installed if they were built for the version that's
  currently installed, unless you pass `--force`. You also can't build a
  patch on top of an already patched system; run `restore` first.
- `pkgman install <files>` replaces `haiku` and `haiku_devel` together.
  `haiku_devel` is skipped if it isn't installed.
- Changes to the system package take effect at the next boot.
- **Rollback without the tool:** the package daemon keeps the previous state
  in `/boot/system/packages/administrative/state_*`. Hold **Space** (or
  Shift) while booting to open the boot loader menu. Choose *Select boot
  volume/state*, pick the boot volume, and choose the state from before the
  install. Once that state is running, run `haiku-syspatch restore` to make it
  permanent. (`pkgman full-sync` also goes back to the repository versions.)
- Nothing is installed without confirmation, except with `--yes`.

### 6. Limits

- Patches must only change the system packages. A patch that changes the boot
  loader would need `haiku_loader` and `makebootable`; that isn't handled.
- The kernel inside `haiku.hpkg` is rebuilt as well. If the patch doesn't
  touch the kernel, it's built from identical source.
- Only `x86_64` is supported, and the tool refuses other architectures.
  32-bit hybrid systems (x86_gcc2 + x86) would need the legacy GCC 2 cross
  tools as well.
- Building needs network access (source and HaikuPorts build packages), about
  20 GiB of disk space and time.

## Building on Linux instead

To build a complete image, or when the Haiku machine is too slow, use the
standard cross-build. These are the steps used for the keyboard-grab test
image:

```sh
git clone --filter=blob:none -b r1beta6 https://github.com/haiku/haiku
git -C haiku fetch https://review.haiku-os.org/haiku refs/tags/hrev59866:refs/tags/hrev59866
git clone --depth 1 -b r1beta6 https://github.com/haiku/buildtools
(cd buildtools/jam && make && cp bin.linux*/jam ~/bin/)
cd haiku && git apply /path/to/haiku-keyboard-grab.patch
mkdir generated.x86_64 && cd generated.x86_64
../configure -j12 --cross-tools-source ../../buildtools --build-cross-tools x86_64
jam -q -j12 -sHAIKU_REVISION=hrev59866+101+kbgrab @release-anyboot
jam -q -j12 -sHAIKU_REVISION=hrev59866+101+kbgrab haiku.hpkg haiku_devel.hpkg
```
