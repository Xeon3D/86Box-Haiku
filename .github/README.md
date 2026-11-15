86Box for Haiku
===============

This is [86Box](https://github.com/86Box/86Box) with Haiku support. It's
merged with 86Box's `master` every day. 86Box's own README is in
[`README.md`](../README.md).

There are two Haiku versions. Both are built from this tree, and you choose
one when you configure:

| Version | Configure with | Package |
|---|---|---|
| Qt 6 UI, the same UI as on other systems | `-D QT=ON -D USE_QT6=ON` | `86box` |
| Native Haiku UI, written with the Be API and modelled on the Qt UI | `-D HAIKU_NATIVE=ON` | `86box_native` |

A single binary can't contain both UIs, because each UI provides the same
platform functions to the emulator core (`main`, `plat_*` and `ui_*`). The
two packages conflict, so only one can be installed at a time.

## Download

[Releases](https://github.com/Xeon3D/86Box-Haiku/releases) has a `.hpkg`
and a `.zip` of each version for Haiku R1/beta6 x86_64.

- **`.hpkg`:** run `pkgman install ./86box-….hpkg` (or `86box_native-…`).
  This puts 86Box in the Deskbar's Applications menu and installs the
  libraries it needs.
- **`.zip`:** unpack it anywhere. `README-Haiku.txt` inside lists the
  libraries to install with `pkgman`.

The ROMs aren't included. Get them from
[86Box/roms](https://github.com/86Box/roms) and put them in
`~/config/non-packaged/data/86Box/roms`.

## Building

On Haiku R1/beta6 x86_64:

```sh
pkgman install cmake ninja pkgconfig qt6_base_devel qt6_tools_devel \
    libsdl2_devel libsdl3_devel freetype_devel libpng16_devel zlib_devel \
    zstd_devel openal_devel libslirp_devel rtmidi_devel fluidsynth2_devel \
    libsndfile_devel mesa_devel
cmake -S . -B build --preset regular -G Ninja -D QT=ON -D USE_QT6=ON \
    -D CMAKE_POLICY_VERSION_MINIMUM=3.5      # or -D HAIKU_NATIVE=ON
cmake --build build
tools/haiku-package.sh qt build dist         # or: native build dist
```

`CMAKE_POLICY_VERSION_MINIMUM` works around Haiku's `OpenALConfig.cmake`,
which CMake 4 rejects. The [Haiku workflow](workflows/haiku.yml) builds both
versions in a Haiku VM on every push.

## Keyboard capture

While the mouse is captured, 86Box tries to send every key to the emulated
machine, including Haiku's own shortcuts: Command+F-keys for workspaces,
Ctrl+Tab for the switcher, Command+Q and so on.

- The full grab needs `BWindow::SetKeyboardGrab()`, which stock Haiku
  doesn't have yet.
  [Haiku-grab-patcher](https://github.com/Xeon3D/Haiku-grab-patcher)
  rebuilds your Haiku system package with it. 86Box looks the function up
  when it runs, so the same binary works on stock and patched systems.
- **Qt UI:** it uses the grab when the system has it and the keyboard hook
  option is on. On stock Haiku the shortcuts stay with Haiku.
- **Native UI:** by default it unassigns the Command keys while the mouse
  is captured. This works on stock Haiku and stops most of the shortcuts.
  On a patched system, *Preferences > Input > Use Haiku's keyboard grab*
  switches to the full grab.
- Ctrl+Alt+Del always opens Team Monitor.

The research and design are in
[`doc/haiku-keyboard-grab.md`](../doc/haiku-keyboard-grab.md).
