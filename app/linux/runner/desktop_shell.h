#ifndef RUNNER_DESKTOP_SHELL_H_
#define RUNNER_DESKTOP_SHELL_H_

#include <gio/gio.h>

// FamChat's place in the Linux desktop shell, over the session D-Bus with
// GDBus only (no extra libraries):
//  - a tray icon: a StatusNotifierItem (KDE Plasma; GNOME with the AppIndicator
//    extension; most other panels) with a com.canonical.dbusmenu menu;
//  - the launcher's unread count: com.canonical.Unity.LauncherEntry (Plasma's
//    task manager, Dash to Dock, Ubuntu Dock).
// Without a session bus, or without a StatusNotifierWatcher, it does nothing
// and says the tray is unavailable.

typedef struct _DesktopShell DesktopShell;

typedef struct {
  // The tray icon was clicked, or "Open FamChat" chosen. |activation_token| is
  // an XDG activation token from the tray host, or null.
  void (*activate)(const gchar* activation_token, gpointer user_data);
  // "Quit" was chosen.
  void (*quit)(gpointer user_data);
  // A tray host appeared or went away.
  void (*tray_available_changed)(gboolean available, gpointer user_data);
  gpointer user_data;
} DesktopShellCallbacks;

DesktopShell* desktop_shell_new(const gchar* app_id,
                                const DesktopShellCallbacks* callbacks);
void desktop_shell_free(DesktopShell* self);

// Whether a StatusNotifierWatcher runs on the session bus.
gboolean desktop_shell_tray_available(DesktopShell* self);

// Whether the tray icon is registered with the watcher, so the user can reach
// a hidden window through it.
gboolean desktop_shell_tray_shown(DesktopShell* self);

// Shows or hides the tray icon. |pixmaps| is an a(iiay) of ARGB32 icons
// (StatusNotifierItem's IconPixmap), floating or not; it may be null to keep
// the current icon.
void desktop_shell_set_tray(DesktopShell* self, gboolean visible,
                            const gchar* tooltip, GVariant* pixmaps);

// Sets the launcher's count; 0 hides it.
void desktop_shell_set_count(DesktopShell* self, gint64 count);

#endif  // RUNNER_DESKTOP_SHELL_H_
