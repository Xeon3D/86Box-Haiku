# Keyboard grab for Haiku: research, design and prototype

Status: research and private prototype, November 2026.
Haiku source examined: `haiku/haiku` master at
[`1371f07efdd`](https://github.com/haiku/haiku/tree/1371f07efddd8a1cc4947bcb869ad8f3b2a9cf0a)
(2026-11-14). Line numbers below refer to that commit.

> [!IMPORTANT]
> **Haiku does not accept AI-generated contributions.** Haiku's
> [`AGENTS.md`](https://github.com/haiku/haiku/blob/master/AGENTS.md) says:
> "Code, documentation, or any other materials generated or modified with AI
> assistance are not accepted." It was added in Gerrit change 11180. The
> [copyright policy](https://www.haiku-os.org/community/organization/policies/)
> also says this "includes most content produced with the use of LLMs".
>
> The prototype in `haiku-keyboard-grab.patch` was written with Claude, so it
> **must not be submitted to Haiku as it is**, and neither may parts of it or
> this text. Use it as a private reference that shows the design works and
> where the code has to change. The code, the commit messages and the
> mailing-list proposal that go upstream have to be written by a person.
> Section 7 describes a route that fits the policy.

## 1. Problem

When 86Box (or QEMU, VirtualBox, DOSBox, an SDL game, etc.) captures the
mouse, the guest should receive every key. On Haiku it can't, because key
combinations are taken away at three levels before the application sees them.
None of these levels can be overridden by an application. The default PC
keymap maps Alt to Command, so for example Alt+F4 in the guest switches the
host to workspace 4.

## 2. Current behaviour

Key events travel through the following stages. Each stage can consume keys.

```
keyboard driver
  -> input_server: keyboard device add-on    (Team Monitor, Menu key)
  -> input_server: input methods
  -> input_server: filter add-ons            (Shortcuts preflet, workspace arrows)
  -> app_server:   EventDispatcher + KeyboardFilter  (Cmd+F-keys, Cmd+`, Stack & Tile)
  -> client:       BWindow::DispatchMessage -> _HandleKeyDown  (Ctrl+Tab, Cmd+Q, PrtScr, shortcuts)
  -> BView::KeyDown()
```

### 2.1 input_server: keyboard device add-on

[`KeyboardInputDevice.cpp:324`](https://github.com/haiku/haiku/blob/1371f07efddd8a1cc4947bcb869ad8f3b2a9cf0a/src/add-ons/input_server/devices/keyboard/KeyboardInputDevice.cpp#L324)
detects **Control+Command+Delete** (Ctrl+Alt+Del on a PC keymap) and opens
the **Team Monitor**. This happens in the device's reader thread, before input
methods and filters run, so nothing downstream can block it.

* The key events are *not* consumed. The Delete key-down is still enqueued and
  can reach the focused window.
* The Team Monitor window uses `B_MODAL_ALL_WINDOW_FEEL`
  ([`TeamMonitorWindow.cpp:155`](https://github.com/haiku/haiku/blob/1371f07efddd8a1cc4947bcb869ad8f3b2a9cf0a/src/add-ons/input_server/devices/keyboard/TeamMonitorWindow.cpp#L155)),
  so it takes focus when it appears.
* The check uses the *left* Control and *left* Command keycodes from the
  current keymap: `fCommandKey = fKeymap.KeyForModifier(B_LEFT_COMMAND_KEY)`
  ([L530-531](https://github.com/haiku/haiku/blob/1371f07efddd8a1cc4947bcb869ad8f3b2a9cf0a/src/add-ons/input_server/devices/keyboard/KeyboardInputDevice.cpp#L530)).
  If the left Command key is unassigned in the keymap, Ctrl+Alt+Del stops
  working (see section 8).
* The Menu key (0x68) pressed on its own sends `'BeMn'` to Deskbar
  ([L300](https://github.com/haiku/haiku/blob/1371f07efddd8a1cc4947bcb869ad8f3b2a9cf0a/src/add-ons/input_server/devices/keyboard/KeyboardInputDevice.cpp#L300)).
  It isn't consumed either.

### 2.2 input_server: filter add-ons

`InputServer::_EventLoop()` runs `_SanitizeEvents`, then `_MethodizeEvents`,
then `_FilterEvents`
([`InputServer.cpp:1602`](https://github.com/haiku/haiku/blob/1371f07efddd8a1cc4947bcb869ad8f3b2a9cf0a/src/servers/input/InputServer.cpp#L1602)).
The Haiku package ships these keyboard filters
([`build/jam/packages/Haiku:435`](https://github.com/haiku/haiku/blob/1371f07efddd8a1cc4947bcb869ad8f3b2a9cf0a/build/jam/packages/Haiku#L435)):

* `switch_workspace`: Command+Control(+Shift)+arrow keys switch to the
  neighbouring workspace
  ([`SwitchWorkspaceInputFilter.cpp:37`](https://github.com/haiku/haiku/blob/1371f07efddd8a1cc4947bcb869ad8f3b2a9cf0a/src/add-ons/input_server/filters/switch_workspace/SwitchWorkspaceInputFilter.cpp#L37)).
* `shortcut_catcher`: the user's global hotkeys from the Shortcuts preflet
  ([`ShortcutsServerFilter.cpp:66`](https://github.com/haiku/haiku/blob/1371f07efddd8a1cc4947bcb869ad8f3b2a9cf0a/src/add-ons/input_server/filters/shortcut_catcher/ShortcutsServerFilter.cpp#L66)).
* `screen_saver`: watches all events to reset the idle timer. It never
  consumes keys, but it must keep seeing them.

(`minimize_all` exists in the tree but isn't shipped.)

### 2.3 `set_modifier_key()` / `IS_SET_MODIFIER_KEY`

`InputServer::HandleSetModifierKey()`
([`InputServer.cpp:699`](https://github.com/haiku/haiku/blob/1371f07efddd8a1cc4947bcb869ad8f3b2a9cf0a/src/servers/input/InputServer.cpp#L699))
does three things:

1. It changes the in-memory keymap.
2. It posts `IS_SAVE_KEYMAP`
   ([L747](https://github.com/haiku/haiku/blob/1371f07efddd8a1cc4947bcb869ad8f3b2a9cf0a/src/servers/input/InputServer.cpp#L747)),
   which **writes `~/config/settings/Key_map` to disk** (`_SaveKeymap`,
   [L295](https://github.com/haiku/haiku/blob/1371f07efddd8a1cc4947bcb869ad8f3b2a9cf0a/src/servers/input/InputServer.cpp#L295)).
3. It tells the keyboard devices `B_KEY_MAP_CHANGED`.

So a temporary change to a modifier key is persistent and global. If the
program that made it dies, the change stays in place across reboots.

### 2.4 app_server: `KeyboardFilter` and desktop listeners

`EventDispatcher::_EventLoop()` holds the dispatcher lock and calls the
keyboard filter for every key, modifier and input-method event, passing
`&fFocus` as the target (`EventDispatcher.cpp` around L894).
`KeyboardFilter::Filter()`
([`Desktop.cpp:184`](https://github.com/haiku/haiku/blob/1371f07efddd8a1cc4947bcb869ad8f3b2a9cf0a/src/servers/app/Desktop.cpp#L184))
handles these keys:

* **Shift+Command+Control+Escape** runs `screenmode --fall-back`
  (safe video mode,
  [L198](https://github.com/haiku/haiku/blob/1371f07efddd8a1cc4947bcb869ad8f3b2a9cf0a/src/servers/app/Desktop.cpp#L198)).
* **Command+F1…F12** switches workspace; with Shift it also takes the window
  along
  ([L204](https://github.com/haiku/haiku/blob/1371f07efddd8a1cc4947bcb869ad8f3b2a9cf0a/src/servers/app/Desktop.cpp#L204)).
* **Command+`** (key 0x11) goes back to the previous workspace
  ([L219](https://github.com/haiku/haiku/blob/1371f07efddd8a1cc4947bcb869ad8f3b2a9cf0a/src/servers/app/Desktop.cpp#L219)).
* `_UpdateFocus()` then sets the event target to `Desktop::KeyboardEventTarget()`
  ([L2050](https://github.com/haiku/haiku/blob/1371f07efddd8a1cc4947bcb869ad8f3b2a9cf0a/src/servers/app/Desktop.cpp#L2050)).
  That is the focus window, or a top-most window with
  `kAcceptKeyboardFocusFlag`.
* `Desktop::KeyEvent()`
  ([L688](https://github.com/haiku/haiku/blob/1371f07efddd8a1cc4947bcb869ad8f3b2a9cf0a/src/servers/app/Desktop.cpp#L688))
  offers the key to desktop listeners. **Stack & Tile** consumes
  Option+arrow/Tab/PageUp/PageDown while the Option key is held
  ([`StackAndTile.cpp:133`](https://github.com/haiku/haiku/blob/1371f07efddd8a1cc4947bcb869ad8f3b2a9cf0a/src/servers/app/stackandtile/StackAndTile.cpp#L133)).

After the filter, the event goes to the focus window and to every view in any
team that registered with `SetEventMask(B_KEYBOARD_EVENTS)`. Those listeners
receive keys even when their window isn't focused.

### 2.5 Client side: `BWindow::_HandleKeyDown()`

`BWindow::DispatchMessage()` calls `_HandleKeyDown()` for `B_KEY_DOWN`
([`Window.cpp:3682`](https://github.com/haiku/haiku/blob/1371f07efddd8a1cc4947bcb869ad8f3b2a9cf0a/src/kits/interface/Window.cpp#L3682))
and `_HandleUnmappedKeyDown()` for `B_UNMAPPED_KEY_DOWN`
([L3854](https://github.com/haiku/haiku/blob/1371f07efddd8a1cc4947bcb869ad8f3b2a9cf0a/src/kits/interface/Window.cpp#L3854))
before the focus view sees the key. `_HandleKeyDown()` handles:

* Command+Escape: menu bar
* Option+Tab: keyboard navigation
* **Control+Tab and Control+`**: the Deskbar switcher (sends `'TASK'` to
  Deskbar,
  [L3717](https://github.com/haiku/haiku/blob/1371f07efddd8a1cc4947bcb869ad8f3b2a9cf0a/src/kits/interface/Window.cpp#L3717))
* Escape with `B_CLOSE_ON_ESCAPE`
* **PrtScr**: screenshot
* **Command+Q**
* Command+Left/Right for text views
* every `AddShortcut()` shortcut, including the default Command+W/Q/X/C/V/A
  ones

The application controls this level already. Overriding
`DispatchMessage()` and not passing key messages to
`BWindow::DispatchMessage()` avoids all of it. The SDL backend doesn't do that:
`SDL_BWin::DispatchMessage()` always forwards, to keep Command+Q.

### 2.6 Existing mechanisms that come close but don't solve it

| Mechanism | What it does | Why it isn't enough |
|---|---|---|
| `SetEventMask(B_KEYBOARD_EVENTS)` | The view receives keys even when not focused (a listener) | Listeners run after the app_server filter, so they never see consumed keys. Not exclusive. |
| `B_LOCK_WINDOW_FOCUS` / `SetFocusLocked()` | Keeps focus during a mouse drag | Only valid while a mouse button is down (`Desktop::SetFocusLocked`, [L2190](https://github.com/haiku/haiku/blob/1371f07efddd8a1cc4947bcb869ad8f3b2a9cf0a/src/servers/app/Desktop.cpp#L2190)). Doesn't affect shortcuts. |
| `B_SUSPEND_VIEW_FOCUS`, `B_NO_POINTER_HISTORY` | Pointer-event delivery options | Not related to keyboard shortcuts |
| `B_NO_SERVER_SIDE_WINDOW_MODIFIERS` | Disables app_server's window-management mouse modifiers (`DefaultWindowBehaviour.cpp:1015`) | Mouse only |
| `BWindowScreen` / `BDirectWindow` fullscreen | Exclusive framebuffer access | No keyboard exclusivity; Command+F-keys still switch workspaces |
| `set_modifier_key()` | Unassigns the Command keys | Global, saved to disk, and breaks Ctrl+Alt+Del (sections 2.1 and 2.3) |

### 2.7 Prior discussion and other toolkits

* **Trac**: no ticket asks for a keyboard grab. Related, closed tickets:
  * #10461: Command shortcuts are eaten in `BWindow::DispatchMessage()`
    before a `B_KEYBOARD_EVENTS` view sees them.
  * #15254: BWindow handling key messages for views.
  * #4208: MediaPlayer blocked Ctrl+Alt+arrow workspace switching. It was
    fixed in favour of the system shortcut.
  * #4184, #6925, #9785: workspace shortcut conflicts.
  * #2499: open; asks for scancode-based hotkeys.
* **Forum**: in
  [disable-ctrl-alt-workspaces-hotkey/1713](https://discuss.haiku-os.org/t/disable-ctrl-alt-workspaces-hotkey/1713)
  (2009), DOSBox and FCEU users patched libbe themselves.
  [workspaces-command-line…/18551](https://discuss.haiku-os.org/t/workspaces-command-line-was-key-combo-remapping/18551)
  (2026) says the built-in workspace keys can't be remapped.
* **Mailing list and Gerrit**: no thread or change about a keyboard grab was
  found. The Trac web UI blocks automated access, so that search may be
  incomplete.
* **SDL2 and SDL3** (`src/video/haiku/`):
  * `SetWindowKeyboardGrab` isn't implemented.
  * `HAIKU_SetWindowMouseGrab` is `// TODO` / `SDL_Unsupported()`.
  * Relative mouse mode only sets `B_NO_POINTER_HISTORY`.
* **Qt Haiku plugin** (`qthaikuplugins`): `setKeyboardGrabEnabled()` and
  `setMouseGrabEnabled()` just `return false`.
* **QEMU's native Haiku UI** (HaikuPorts patchset, `ui/haiku.cpp`): the grab
  only happens inside the app, through a `BMessageFilter`. Workspace keys
  still switch workspaces.

The new API maps directly onto `SDL_SetWindowKeyboardGrab()` and
`QWindow::setKeyboardGrabEnabled()`, so both ports could implement it in a
few lines.

## 3. Requirements

1. Only the **active, focused** window can hold the grab. A background team
   can't grab.
2. The grab is **released automatically** when:
   * the window loses focus (another window is activated, a modal window
     appears, the window is hidden or minimized, or the workspace changes),
   * the window closes, or
   * the team dies.

   It is never restored silently. The app has to grab again, normally when it
   captures the mouse again.
3. While the grab is held, keys that would otherwise go to the system reach
   the window:
   * workspace switching (app_server and the input_server filter),
   * the user's global Shortcuts,
   * Stack & Tile,
   * the Deskbar switcher and BWindow's built-in shortcuts.
4. These keys **always get through to the system**, even during a grab:
   * **Ctrl+Alt+Del** (Team Monitor). This is the secure attention sequence,
     as on Windows. Team Monitor is modal-all, so opening it moves focus and
     ends the grab.
   * **Shift+Ctrl+Alt+Esc** (safe video mode fallback). This is a recovery
     key; a monitor or app combination that leaves the screen unusable is
     exactly when you need it.
   * Kernel-level keys: Alt+SysRq (KDL), power button / ACPI. These live
     below input_server and are unaffected.
   * The mouse. Clicking another window or Deskbar changes focus and so ends
     the grab. This doesn't help if the app has also captured the mouse,
     which is why Ctrl+Alt+Del matters.
5. A grab never hides keys from the system's view of activity. The screen
   saver still sees them.
6. Binary compatibility: no virtual functions, no changes to class sizes, and
   old apps behave exactly as before.

## 4. API options

| Shape | Pros | Cons |
|---|---|---|
| **A. `SetEventMask(B_KEYBOARD_EVENTS, B_GRAB_KEYBOARD)`** (new event-mask option on `BView`) | No new methods. Per view. | `B_KEYBOARD_EVENTS` already means "listen even when *not* focused", which is the opposite of the focus-only semantics needed here. The option bits are pointer-oriented. `SetMouseEventMask` is temporary and the plain mask is persistent, so it's unclear which one a grab belongs to. Error reporting is awkward because the setter returns a status only for the mask. |
| **B. Window flag** such as `B_GRAB_KEYBOARD_WHEN_ACTIVE` (`SetFlags()`) | Declarative. No race between activation and grab. | It re-grabs on every activation without a user action, which is weaker against abuse. Emulators toggle the grab on every mouse capture/release, which doesn't fit a window property. Uses one of the few free public flag bits. No way to report "not allowed". |
| **C. `status_t BWindow::SetKeyboardGrab(bool)` + `bool BWindow::HasKeyboardGrab() const`** | Explicit and transient. Returns `B_NOT_ALLOWED` when the window isn't focused. Same shape as SDL and Qt. Two non-virtual methods are ABI-safe (new exported symbols only, no vtable or layout change). | Two new public methods to document and keep. The client has to re-grab after re-activation, which is intended. |
| D. App-wide (`BApplication`/`BRoster`) | — | Too coarse. Grabs are per window in every other system. |

**Recommendation: C.** It matches the semantics (a temporary, focus-bound,
revocable request), returns a clear error, and maps one-to-one onto SDL and
Qt.

The client finds out the grab was lost through `WindowActivated(false)`,
which every focus loss already triggers. No new hook is needed.

Naming alternatives for upstream review: `GrabKeyboard(bool)` /
`IsKeyboardGrabbed()`, or `SetKeyboardGrabbed()`. Haiku prefers `IsX()` /
`HasX()` getters without `Get`.

## 5. The prototype (`haiku-keyboard-grab.patch`)

The patch is against `1371f07efdd`: 16 files, about +450 lines, including a
167-line test app. **It's a private reference and not for submission** (see
the note at the top).

### 5.1 Public API: Interface Kit

* `headers/os/interface/Window.h`: adds `status_t SetKeyboardGrab(bool grab)`
  and `bool HasKeyboardGrab() const`. Both are non-virtual, with no data
  members.
* `src/kits/interface/Window.cpp`:
  * The two methods send `AS_SET_KEYBOARD_GRAB` / `AS_GET_KEYBOARD_GRAB`
    synchronously.
  * `_HandleKeyDown()` and `_HandleUnmappedKeyDown()` return early when the
    event carries `be:keyboard_grab`, so the focus view receives Ctrl+Tab,
    Command+Q, PrtScr and the shortcuts unchanged.
  * The method documentation is Doxygen-style in the `.cpp`. Real
    documentation would go in `docs/user/interface/Window.dox`.

### 5.2 Protocol

* `ServerProtocol.h`: `AS_SET_KEYBOARD_GRAB` and `AS_GET_KEYBOARD_GRAB`,
  after `AS_IS_FRONT_WINDOW`. This is a private protocol, and libbe and
  app_server ship together.
* `InputServerTypes.h`: `IS_SET_KEYBOARD_GRAB 'Iskg'`.
* Message field `"be:keyboard_grab"` (bool). It is added to keyboard events
  while a grab is active, and nobody else is trusted to set it.

### 5.3 app_server

* **`Desktop`**:
  * New member `fKeyboardGrabWindow`.
  * `SetKeyboardGrab(window, grab)` holds the all-window lock and grants the
    grab only if `window == fFocus` and the window isn't hidden; otherwise it
    returns `B_NOT_ALLOWED`.
  * `_ReleaseKeyboardGrab()` is called from `SetFocusWindow()` whenever focus
    moves to another window. That covers activation, modal windows, Team
    Monitor, hide/minimize, workspace switches and quitting. It is also
    called from `RemoveWindow()` as a safety net.
  * `IsKeyboardGrabTarget(target)` checks a target under the single-window
    read lock.
* **`KeyboardFilter::Filter()`**:
  * Updates the focus first.
  * Strips any `be:keyboard_grab` already on the message and adds it again
    only if the event's target is the window holding the grab.
  * Always handles safe video mode.
  * If grabbed, returns `B_DISPATCH_MESSAGE` for key-down events before
    workspace switching and before the desktop listeners (Stack & Tile).
  * Modifier changes and key-ups still go to listeners, so Stack & Tile's
    Option tracking stays consistent.
  * A window with `kAcceptKeyboardFocusFlag` on top (menus, the input-method
    bottom line) makes the grab inactive for those events.
* **`ServerWindow`**: handles the two new codes. `AS_SET_KEYBOARD_GRAB`
  drops the single-window lock before calling into the Desktop, following the
  `AS_ACTIVATE_WINDOW` pattern.
* **`EventDispatcher::SetKeyboardGrab()`** calls the new
  **`EventStream::SetKeyboardGrab()`** (a default no-op virtual), and
  `InputServerStream` sends `IS_SET_KEYBOARD_GRAB` to input_server with a
  50 ms timeout.
* Lock order: the event loop holds the dispatcher lock and then takes the
  window lock in the filter. Desktop calls this notification while holding
  the window lock, so the call must **not** take the dispatcher lock;
  otherwise the two could deadlock. It reads `fStream` without locking
  (`fStream` is only set during startup). Desktop notifies while still
  holding the all-window lock, so input_server receives grab/release
  messages in order.

### 5.4 input_server

* `InputServer` stores `fKeyboardGrabbed` atomically when it receives
  `IS_SET_KEYBOARD_GRAB`.
* `_FilterEvents()` strips and re-adds `be:keyboard_grab` on keyboard events
  before running the filters. Filters still see every event, so the screen
  saver keeps working.
* `switch_workspace` and `shortcut_catcher` pass marked events through.
  Third-party filters can do the same.
* The keyboard device add-on is unchanged, so Ctrl+Alt+Del → Team Monitor
  works during a grab.

### 5.5 Test app

`src/tests/servers/app/keyboard_grab/GrabTest.cpp` (in the patch; no Jamfile)
does the following:

* Logs every keyboard message in `DispatchMessage()`, before BWindow can eat
  shortcuts, with `[grab]` when the event is marked.
* Logs `WindowActivated()`, and warns if a grab survives deactivation.
* Toggles the grab with a mouse click.
* Build it with `g++ -o GrabTest GrabTest.cpp -lbe`. Add `-DNO_GRAB_API` for
  a stock system, which gives a baseline log.

### 5.6 Known gaps and open questions for upstream

1. **Unauthenticated `IS_SET_KEYBOARD_GRAB`.** Any local app could send it
   to input_server and make the shortcut filters ignore keys. This only
   denies the user's hotkeys and doesn't affect Team Monitor, but it should be
   fixed. Options: have input_server check that the sender is the app_server
   team (`fAppServerTeam`), or have app_server mark the grab in the event
   stream it already shares with input_server.
2. **Ctrl+Alt+Del keys still reach the grabbing window** before Team Monitor
   takes focus, which is also the case today. On Windows the secure attention
   sequence is never delivered to apps. A follow-up could have the keyboard
   device stop enqueuing the Delete down/up while it handles the sequence.
3. **`B_KEYBOARD_EVENTS` listeners in other teams** still receive keys during
   a grab, as before. Should a grab make them exclusive?
4. **Input methods** run before the filters and are not bypassed. They are
   probably fine, since the user enables them explicitly.
5. Should the user see that a grab is active, for example in Deskbar? Windows
   doesn't show it. Emulators already show "press X to release" in the title.
6. Haiku Book docs (`docs/user/interface/Window.dox`) and a
   `B_HAIKU_VERSION` bump or note so apps can detect the API.

## 6. Testing done

On the R1/beta6 x86_64 VM (GCC 13.3):

* **Compile check.** All 8 changed C++ sources compile cleanly with
  `g++ -fsyntax-only` against the patched headers:
  * `Window.cpp`
  * `Desktop.cpp`
  * `ServerWindow.cpp`
  * `EventDispatcher.cpp`
  * `EventStream.cpp`
  * `InputServer.cpp`
  * the two filters

  This used the patched tree with real private headers (plus a stub for the
  generated `SystemKeymap.h`).
* **Test app.** `GrabTest` links against stock `libbe` with
  `-DNO_GRAB_API`, and passes a syntax check against the patched headers.
* **Patch.** It reverse-applies cleanly on top of the patched checkout
  (`git apply --check -R`).

**Not done:**

* No jam build of `libbe.so`, `app_server` or `input_server`.
* No runtime test.

Replacing system servers on the VM needs a rebuilt `haiku.hpkg`, which
requires the user's approval, so nothing was installed. The prototype files
are in `~/kbgrab` on the VM. No 86Box VM or emulator process was touched.

How to run it:

1. Build the patched tree with jam, either on a Linux host with buildtools
   or on Haiku with `jam -q haiku.hpkg`. A `jam -q @nightly-anyboot` image is
   the cleanest option.
2. Boot that image in a separate VM, or install the `.hpkg` into a snapshot
   of the test VM. Haiku's boot-menu package states provide a rollback.
3. Run `GrabTest` from Terminal, click to grab, and check each case:

| Case | Expected |
|---|---|
| Alt+F2, Alt+`, Ctrl+Alt+arrows | Logged with `[grab]`; the workspace doesn't change |
| Ctrl+Tab, Alt+Q, PrtScr, Alt+W | Logged; no switcher, no quit, no screenshot |
| A hotkey from the Shortcuts preflet | Logged; the command doesn't run |
| Option held + arrows (Stack & Tile) | Logged |
| Ctrl+Alt+Del | Team Monitor opens; the log shows `WindowActivated(false)`; after closing Team Monitor, Alt+F2 switches workspace again |
| Shift+Ctrl+Alt+Esc | Safe video mode still triggers |
| Click another window, minimize, close | The grab is released; the system shortcuts work again |
| Grab request while not focused (e.g. from a `BMessageRunner`) | `B_NOT_ALLOWED` |
| Screen saver timeout while typing in the grabbed window | Doesn't trigger |

## 7. Getting it into Haiku

1. **Respect the AI policy.** The upstream patch has to be the user's own
   work, written by hand. The prototype is a map of the code, not a patch to
   send. The same applies to the text of a proposal: write it yourself, using
   this document only as your own notes.
2. **Discuss the API first.** No written rule requires it, but new public
   Interface Kit API is normally discussed before code review.
   * Post a short design on the
     [haiku-development mailing list](https://www.freelists.org/list/haiku-development)
     or in the forum's Development category: the problem, the method
     signatures, the release rules, the always-allowed keys, and the open
     questions from section 5.6.
   * Optionally open a Trac **enhancement** ticket ("Interface Kit: allow a
     focused window to grab the keyboard") and link it.
   * Point to the SDL/Qt `TODO`s and the emulator use case. Developers likely
     to weigh in include axeld (app_server design), waddlesplash and
     PulkoMandy.
3. **Gerrit.**
   * Sign in to review.haiku-os.org with GitHub and add an ed25519 SSH key.
   * Install the `commit-msg` hook (for Change-Id).
   * Push with `git push origin HEAD:refs/for/master -o topic=keyboard-grab`.
     GitHub PRs aren't accepted.
   * Guides:
     [getting the source / submitting](https://www.haiku-os.org/guides/building/get-source-git/),
     [coding guidelines](https://www.haiku-os.org/development/coding-guidelines).
     Note the tabs, 80 columns, `/*! */` doc comments and the
     `fMember`/`_Private` naming.
4. **Split the change** into reviewable commits, each with a component
   prefix and a first line under 64 characters:
   * `app_server: Add keyboard grab support`
   * `input_server: Let filters skip grabbed keyboard events`
   * `Interface Kit: Add BWindow::SetKeyboardGrab()`
   * `docs: Document BWindow keyboard grab`
   * optionally `keyboard input device: Swallow the Team Monitor key sequence`

   Reference the Trac ticket as `#NNNNN`.
5. **After it merges:**
   * Implement `HAIKU_SetWindowKeyboardGrab` in SDL3 (and possibly SDL2).
   * Implement `setKeyboardGrabEnabled` in qthaikuplugins.
   * Use it in 86Box's Haiku frontend. Detect it at compile time with a
     Haiku version check, and keep the stopgap for older releases.

## 8. Notes for the 86Box stopgap (until this exists)

1. `set_modifier_key()` writes `Key_map` to disk (section 2.3). Save the
   original Command keycodes to a file in 86Box's own settings directory
   before changing them, and restore them on the next start if that file is
   still there. This recovers after a crash or kill.
2. **Unassigning the left Command key disables Ctrl+Alt+Del → Team Monitor**
   (section 2.1), because the device looks the keycode up from the keymap.
   With the stopgap active, a captured 86Box therefore has *no* keyboard
   escape. Consider:
   * unassigning only the right Command key, so left Alt+F-keys still switch
     workspaces but the escape is kept; or
   * making sure the 86Box release hotkey (and mouse release) always works.
3. The client-side shortcuts in section 2.5 (Ctrl+Tab switcher, Command+Q,
   PrtScr, `AddShortcut` ones) can be kept from the host today. Override
   `DispatchMessage()` in the render window and, while captured, send
   `B_KEY_DOWN`/`B_KEY_UP`/`B_UNMAPPED_KEY_*` straight to the view instead of
   to `BWindow::DispatchMessage()`.
4. Unassigning Command stops every Command-based system combination:
   Command+F-keys, Command+` and Command+Control+arrows. It doesn't cover:
   * Shortcuts-preflet hotkeys that don't use Command.
   * Option-held Stack & Tile keys (Option is the Windows key on a PC
     keymap).
