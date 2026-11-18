# Desktop unread badges and close to tray — design

Status: approved by the user on 2026-11-18 (requests #2 "no unread badges … same with linux and
maybe win/mac" and #4 "minimize to tray when closing … tray icon can also show unread count").
Builds on the phone badges (`lib/chat/unread_total.dart`, `lib/push/app_badge.dart`).

## Unread badge

The number is `unreadTotalProvider` (unread across unmuted chats), through the same
`appBadgeProvider` the phones use: updated live, cleared at 0 and on sign-out.

| Platform | Where | How |
|---|---|---|
| macOS | Dock tile badge (full count) | `app_badge_plus`, which already supports macOS |
| Windows | Taskbar button overlay: a red disc reading 1–9 or "9+", description "3 unread" | `ITaskbarList3::SetOverlayIcon` in `windows/runner/flutter_window.cpp`; re-applied on `TaskbarButtonCreated` |
| Linux | Launcher count (Plasma task manager, Dash to Dock, Ubuntu Dock) | `com.canonical.Unity.LauncherEntry` `Update` signal for `application://dev.famchat.app.desktop`, plus `Query`, over GDBus in `linux/runner/desktop_shell.cc` |

The AppImage's `AppRun` already installs its launcher as `dev.famchat.app.desktop`, so the URI
matches.

## Close to tray

A per-device setting (`lib/settings/close_to_tray.dart`, SharedPreferencesAsync key
`close_to_tray`), shown under Settings → Window on the desktop apps only:

- "Close to tray": default **on** on Windows, **off** on Linux.
- macOS: "Keep running in the menu bar", default off (closing the window quits, as before).
- Linux shows it only while a StatusNotifierItem host runs (`org.kde.StatusNotifierWatcher` on the
  session bus, watched live). Without one the option is hidden and closing always quits.

When on, the title bar's close, Alt+F4, the taskbar's Close window and the macOS red button / Cmd+W
hide the window; the app keeps running and connected, so notifications still arrive. The tray icon
(shown only while the setting is on) has "Open FamChat" and "Quit"; a left click (Windows, Linux) or
the Dock icon (macOS, `applicationShouldHandleReopen`) brings the window back, as does a click on a
desktop notification (`lib/push/local_notifier_io.dart`). Quit really quits.

Dart decides through the `famchat/window` channel: it sends `setCloseToTray`, and the title bar's
close calls `hide` or `quit`. The runners handle the system's close themselves from that flag, so a
busy Dart side can't block closing. Safety net: each runner only hides while its tray icon is
actually up (Windows: `Shell_NotifyIcon` succeeded; Linux: the watcher accepted the item; macOS:
the status item exists), otherwise it quits; if the Linux tray host goes away or the Windows icon
is removed while the window is hidden, the window is shown again.

A second launch brings back the running instance instead of starting another (Windows: a named
mutex and a registered window message; Linux: `GApplication` is now unique and `activate` presents
the existing window). macOS is single-instance already.

### Tray icon

The FamChat mark with a red count badge (1–9, "9+") in its lower right when unread > 0; tooltip
"FamChat — 3 unread". The art is drawn in Dart (`lib/window/unread_badge_art.dart`, dart:ui) at
16–64 px, so every platform gets identical, pixel-exact art:

- Windows: BGRA pixels at every size; the runner builds an `HICON` at `SM_CXSMICON` for the
  window's DPI (rebuilt on `WM_DPICHANGED`, re-added on `TaskbarCreated`). The overlay uses the
  same path.
- Linux: ARGB pixmaps (`IconPixmap`) on a StatusNotifierItem with a `com.canonical.dbusmenu`
  menu, all hand-written on GDBus: no libayatana-appindicator, so no new build or runtime
  dependency, no CI or AppImage changes, and nothing to fail to load.
- macOS: an `NSStatusItem` with a template (monochrome) glyph and the count as its title.

## Testing

Dart: label/tooltip formatting and the rendered art, the setting's per-platform defaults,
persistence and Linux hiding without a tray host (injectable `DesktopWindow` fake), close
behaviour over a mocked channel (on → `hide`, off → `quit`), and the providers that drive the
tray and badge. Native: the Linux D-Bus side was exercised against a live Plasma watcher (register,
unregister on hide, tooltip, pixmaps, menu layout and clicks, LauncherEntry `Query`). Windows and
macOS runners are compiled by CI.
