#!/bin/bash
#
# Packages a Haiku build of 86Box as a .zip and an .hpkg.
#
#   tools/haiku-package.sh <qt|native> <build dir> [output dir]
#
# Runs on Haiku. The .hpkg's dependencies are worked out from the libraries
# the binary links to: each one is looked up in /boot/system/lib and its
# owning package (the SYS:PACKAGE attribute that packagefs sets) becomes a
# requirement.
#
# The Qt build is packaged as "86box", the native Be API build as
# "86box_native". Both install /bin/86Box, so they conflict with each other.

set -euo pipefail

die() { echo "haiku-package: $*" >&2; exit 1; }

[ $# -ge 2 ] || die "usage: $0 <qt|native> <build dir> [output dir]"
variant=$1
build=$(cd "$2" && pwd)
out=${3:-$PWD/dist}
src=$(cd "$(dirname "$0")/.." && pwd)

case $variant in
    qt)     pkg=86box;        other=86box_native; ui="Qt 6 user interface" ;;
    native) pkg=86box_native; other=86box;        ui="native Haiku (Be API) user interface" ;;
    *)      die "variant must be qt or native" ;;
esac

[ "$(uname -s)" = Haiku ] || die "run this on Haiku"
bin=$build/src/86Box
[ -x "$bin" ] || die "no binary at $bin"
arch=$(getarch 2>/dev/null || uname -m)

# 7.0 from CMakeLists.txt, then ~git<date> because these are development
# builds of that version (in Haiku's version order "~" sorts first).
base=$(sed -n '/^project(86Box/,/)/s/^ *VERSION \([0-9.]*\).*/\1/p' "$src/CMakeLists.txt")
[ -n "$base" ] || die "could not read the version from CMakeLists.txt"
date=$(git -C "$src" log -1 --format=%cd --date=format:%Y%m%d 2>/dev/null || date +%Y%m%d)
commit=$(git -C "$src" rev-parse --short=9 HEAD 2>/dev/null || echo unknown)
version="${base}~git${date}"
pkgrev=1

work=$(mktemp -d /tmp/86box-package.XXXXXX)
trap 'rm -rf "$work"' EXIT

# --- dependencies ---------------------------------------------------------
requires=()
declare -A seen=()
for lib in $(objdump -p "$bin" | awk '$1 == "NEEDED" { print $2 }'); do
    file=
    for dir in /boot/system/lib /boot/system/develop/lib; do
        if [ -e "$dir/$lib" ]; then file=$(readlink -f "$dir/$lib"); break; fi
    done
    [ -n "$file" ] || die "$lib: not found in /boot/system/lib"
    owner=$(catattr -d SYS:PACKAGE "$file" 2>/dev/null || true)
    [ -n "$owner" ] || die "$lib: $file isn't in a package"
    name=${owner%%-*}
    case $name in
        haiku|haiku_*) continue ;;   # the base system
    esac
    if [ -z "${seen[$name]:-}" ]; then
        seen[$name]=1
        requires+=("$name")
    fi
done
echo "==> $pkg $version-$pkgrev requires: ${requires[*]:-(base system only)}"

# --- package contents -----------------------------------------------------
root=$work/root
mkdir -p "$root/apps/86Box" "$root/bin" "$root/data/deskbar/menu/Applications" \
         "$root/documentation/packages/$pkg"
cp "$bin" "$root/apps/86Box/86Box"
strip "$root/apps/86Box/86Box"
ln -s ../apps/86Box/86Box "$root/bin/86Box"
ln -s ../../../../apps/86Box/86Box "$root/data/deskbar/menu/Applications/86Box"
cp "$src/COPYING" "$root/documentation/packages/$pkg/"

readme=$work/README-Haiku.txt
cat > "$readme" << EOF
86Box $version for Haiku $arch, $ui
Built from commit $commit (https://github.com/Xeon3D/86Box-Haiku).

86Box needs its ROM set, which isn't included. Get it from
https://github.com/86Box/roms and put the files in

    ~/config/non-packaged/data/86Box/roms

or in a "roms" folder next to the 86Box binary.

The .hpkg installs 86Box in /boot/system/apps/86Box, adds it to the Deskbar
menu and pulls in the libraries it needs. Install it with

    pkgman install ./$pkg-$version-$pkgrev-$arch.hpkg

To use the .zip instead, install the libraries first:

    pkgman install ${requires[*]:-}

Keyboard capture: while the mouse is captured, the system shortcuts
(Command+F-keys, Ctrl+Tab and so on) go to the emulated machine when the
system has BWindow::SetKeyboardGrab(), which needs a patched Haiku; see
https://github.com/Xeon3D/Haiku-grab-patcher. On an unpatched system 86Box
runs normally and those shortcuts stay with Haiku.
EOF
cp "$readme" "$root/documentation/packages/$pkg/"

{
    echo "name $pkg"
    echo "version $version-$pkgrev"
    echo "architecture $arch"
    echo "summary \"Emulator of x86-based machines ($ui)\""
    echo "description \"86Box is a low-level emulator of x86-based PCs from 1981 to the"
    echo "early 2000s. This build uses the $ui. Built from commit $commit.\""
    echo "packager \"Xeon3D\""
    echo "vendor \"86Box-Haiku\""
    echo "licenses { \"GNU GPL v2\" }"
    echo "copyrights { \"2007-2026 the 86Box contributors\" }"
    echo "urls { \"https://github.com/Xeon3D/86Box-Haiku\" }"
    echo "provides {"
    echo "    $pkg = $version"
    echo "    cmd:86Box = $version"
    echo "    app:86Box = $version"
    echo "}"
    echo "requires {"
    echo "    haiku"
    for r in "${requires[@]}"; do echo "    $r"; done
    echo "}"
    echo "conflicts {"
    echo "    $other"
    echo "}"
} > "$work/.PackageInfo"

mkdir -p "$out"
out=$(cd "$out" && pwd)   # package create and zip run in other directories
hpkg=$out/$pkg-$version-$pkgrev-$arch.hpkg
rm -f "$hpkg"
(cd "$root" && package create -q -i "$work/.PackageInfo" "$hpkg")

zipdir=$work/zip/86Box
mkdir -p "$zipdir"
cp "$root/apps/86Box/86Box" "$src/COPYING" "$readme" "$zipdir/"
zip=$out/86Box-Haiku-$variant-$version-$arch.zip
rm -f "$zip"
(cd "$work/zip" && zip -qry "$zip" 86Box)

echo "==> $hpkg"
echo "==> $zip"
