#include "desktop_shell.h"

#include <unistd.h>

#include <initializer_list>

// Specs: https://www.freedesktop.org/wiki/Specifications/StatusNotifierItem/
// (org.kde.StatusNotifierItem), libdbusmenu's com.canonical.dbusmenu
// interface, and https://wiki.ubuntu.com/Unity/LauncherAPI.

static const gchar kItemXml[] =
    "<node>"
    " <interface name='org.kde.StatusNotifierItem'>"
    "  <property name='Category' type='s' access='read'/>"
    "  <property name='Id' type='s' access='read'/>"
    "  <property name='Title' type='s' access='read'/>"
    "  <property name='Status' type='s' access='read'/>"
    "  <property name='WindowId' type='i' access='read'/>"
    "  <property name='IconName' type='s' access='read'/>"
    "  <property name='IconPixmap' type='a(iiay)' access='read'/>"
    "  <property name='OverlayIconName' type='s' access='read'/>"
    "  <property name='OverlayIconPixmap' type='a(iiay)' access='read'/>"
    "  <property name='AttentionIconName' type='s' access='read'/>"
    "  <property name='AttentionIconPixmap' type='a(iiay)' access='read'/>"
    "  <property name='AttentionMovieName' type='s' access='read'/>"
    "  <property name='IconThemePath' type='s' access='read'/>"
    "  <property name='ToolTip' type='(sa(iiay)ss)' access='read'/>"
    "  <property name='ItemIsMenu' type='b' access='read'/>"
    "  <property name='Menu' type='o' access='read'/>"
    "  <method name='ContextMenu'>"
    "   <arg name='x' type='i' direction='in'/>"
    "   <arg name='y' type='i' direction='in'/>"
    "  </method>"
    "  <method name='Activate'>"
    "   <arg name='x' type='i' direction='in'/>"
    "   <arg name='y' type='i' direction='in'/>"
    "  </method>"
    "  <method name='SecondaryActivate'>"
    "   <arg name='x' type='i' direction='in'/>"
    "   <arg name='y' type='i' direction='in'/>"
    "  </method>"
    "  <method name='Scroll'>"
    "   <arg name='delta' type='i' direction='in'/>"
    "   <arg name='orientation' type='s' direction='in'/>"
    "  </method>"
    "  <method name='ProvideXdgActivationToken'>"
    "   <arg name='token' type='s' direction='in'/>"
    "  </method>"
    "  <signal name='NewTitle'/>"
    "  <signal name='NewIcon'/>"
    "  <signal name='NewAttentionIcon'/>"
    "  <signal name='NewOverlayIcon'/>"
    "  <signal name='NewToolTip'/>"
    "  <signal name='NewStatus'><arg name='status' type='s'/></signal>"
    " </interface>"
    "</node>";

static const gchar kMenuXml[] =
    "<node>"
    " <interface name='com.canonical.dbusmenu'>"
    "  <property name='Version' type='u' access='read'/>"
    "  <property name='TextDirection' type='s' access='read'/>"
    "  <property name='Status' type='s' access='read'/>"
    "  <property name='IconThemePath' type='as' access='read'/>"
    "  <method name='GetLayout'>"
    "   <arg name='parentId' type='i' direction='in'/>"
    "   <arg name='recursionDepth' type='i' direction='in'/>"
    "   <arg name='propertyNames' type='as' direction='in'/>"
    "   <arg name='revision' type='u' direction='out'/>"
    "   <arg name='layout' type='(ia{sv}av)' direction='out'/>"
    "  </method>"
    "  <method name='GetGroupProperties'>"
    "   <arg name='ids' type='ai' direction='in'/>"
    "   <arg name='propertyNames' type='as' direction='in'/>"
    "   <arg name='properties' type='a(ia{sv})' direction='out'/>"
    "  </method>"
    "  <method name='GetProperty'>"
    "   <arg name='id' type='i' direction='in'/>"
    "   <arg name='name' type='s' direction='in'/>"
    "   <arg name='value' type='v' direction='out'/>"
    "  </method>"
    "  <method name='Event'>"
    "   <arg name='id' type='i' direction='in'/>"
    "   <arg name='eventId' type='s' direction='in'/>"
    "   <arg name='data' type='v' direction='in'/>"
    "   <arg name='timestamp' type='u' direction='in'/>"
    "  </method>"
    "  <method name='EventGroup'>"
    "   <arg name='events' type='a(isvu)' direction='in'/>"
    "   <arg name='idErrors' type='ai' direction='out'/>"
    "  </method>"
    "  <method name='AboutToShow'>"
    "   <arg name='id' type='i' direction='in'/>"
    "   <arg name='needUpdate' type='b' direction='out'/>"
    "  </method>"
    "  <method name='AboutToShowGroup'>"
    "   <arg name='ids' type='ai' direction='in'/>"
    "   <arg name='updatesNeeded' type='ai' direction='out'/>"
    "   <arg name='idErrors' type='ai' direction='out'/>"
    "  </method>"
    "  <signal name='ItemsPropertiesUpdated'>"
    "   <arg name='updatedProps' type='a(ia{sv})'/>"
    "   <arg name='removedProps' type='a(ias)'/>"
    "  </signal>"
    "  <signal name='LayoutUpdated'>"
    "   <arg name='revision' type='u'/>"
    "   <arg name='parent' type='i'/>"
    "  </signal>"
    "  <signal name='ItemActivationRequested'>"
    "   <arg name='id' type='i'/>"
    "   <arg name='timestamp' type='u'/>"
    "  </signal>"
    " </interface>"
    "</node>";

static const gchar kLauncherXml[] =
    "<node>"
    " <interface name='com.canonical.Unity.LauncherEntry'>"
    "  <method name='Query'>"
    "   <arg name='app_uri' type='s' direction='out'/>"
    "   <arg name='properties' type='a{sv}' direction='out'/>"
    "  </method>"
    "  <signal name='Update'>"
    "   <arg name='app_uri' type='s'/>"
    "   <arg name='properties' type='a{sv}'/>"
    "  </signal>"
    " </interface>"
    "</node>";

static const gchar kItemPath[] = "/StatusNotifierItem";
static const gchar kItemInterface[] = "org.kde.StatusNotifierItem";
static const gchar kMenuPath[] = "/MenuBar";
static const gchar kLauncherPath[] = "/com/canonical/unity/launcherentry/famchat";
static const gchar kLauncherInterface[] = "com.canonical.Unity.LauncherEntry";
static const gchar kWatcherName[] = "org.kde.StatusNotifierWatcher";

// The tray menu: 0 is its root.
enum { kMenuRoot = 0, kMenuOpen = 1, kMenuSeparator = 2, kMenuQuit = 3 };

struct _DesktopShell {
  DesktopShellCallbacks callbacks;
  gchar* app_id;
  gchar* app_uri;
  GDBusConnection* bus;
  GCancellable* cancellable;
  guint item_registration;
  guint menu_registration;
  guint launcher_registration;
  guint watcher_watch;
  // A StatusNotifierWatcher runs.
  gboolean available;
  // Dart wants the icon shown.
  gboolean want_visible;
  // The well-known name the icon is registered under while shown; giving it
  // up takes the icon away.
  guint name_owner;
  guint name_serial;
  // The watcher accepted the icon.
  gboolean shown;
  gchar* tooltip;
  GVariant* pixmaps;
  gchar* activation_token;
  gint64 count;
};

static GVariant* empty_pixmaps() {
  return g_variant_new_array(G_VARIANT_TYPE("(iiay)"), nullptr, 0);
}

static void emit_item_signal(DesktopShell* self, const gchar* name) {
  if (self->bus == nullptr) return;
  g_dbus_connection_emit_signal(self->bus, nullptr, kItemPath, kItemInterface,
                                name, nullptr, nullptr);
}

// --- org.kde.StatusNotifierItem ---

static GVariant* item_get_property(GDBusConnection* bus, const gchar* sender,
                                   const gchar* path, const gchar* interface,
                                   const gchar* name, GError** error,
                                   gpointer user_data) {
  DesktopShell* self = static_cast<DesktopShell*>(user_data);
  if (g_strcmp0(name, "Category") == 0) {
    return g_variant_new_string("Communications");
  }
  if (g_strcmp0(name, "Id") == 0) return g_variant_new_string(self->app_id);
  if (g_strcmp0(name, "Title") == 0) return g_variant_new_string("FamChat");
  if (g_strcmp0(name, "Status") == 0) return g_variant_new_string("Active");
  if (g_strcmp0(name, "WindowId") == 0) return g_variant_new_int32(0);
  if (g_strcmp0(name, "IconPixmap") == 0) {
    return self->pixmaps != nullptr ? g_variant_ref(self->pixmaps)
                                    : empty_pixmaps();
  }
  if (g_strcmp0(name, "OverlayIconPixmap") == 0 ||
      g_strcmp0(name, "AttentionIconPixmap") == 0) {
    return empty_pixmaps();
  }
  if (g_strcmp0(name, "IconName") == 0 ||
      g_strcmp0(name, "OverlayIconName") == 0 ||
      g_strcmp0(name, "AttentionIconName") == 0 ||
      g_strcmp0(name, "AttentionMovieName") == 0 ||
      g_strcmp0(name, "IconThemePath") == 0) {
    return g_variant_new_string("");
  }
  if (g_strcmp0(name, "ToolTip") == 0) {
    return g_variant_new("(s@a(iiay)ss)", "", empty_pixmaps(),
                         self->tooltip != nullptr ? self->tooltip : "FamChat",
                         "");
  }
  if (g_strcmp0(name, "ItemIsMenu") == 0) return g_variant_new_boolean(FALSE);
  if (g_strcmp0(name, "Menu") == 0) return g_variant_new_object_path(kMenuPath);
  g_set_error(error, G_DBUS_ERROR, G_DBUS_ERROR_UNKNOWN_PROPERTY,
              "No property %s", name);
  return nullptr;
}

static void activate(DesktopShell* self) {
  g_autofree gchar* token = g_steal_pointer(&self->activation_token);
  if (self->callbacks.activate != nullptr) {
    self->callbacks.activate(token, self->callbacks.user_data);
  }
}

static void item_method_call(GDBusConnection* bus, const gchar* sender,
                             const gchar* path, const gchar* interface,
                             const gchar* method, GVariant* parameters,
                             GDBusMethodInvocation* invocation,
                             gpointer user_data) {
  DesktopShell* self = static_cast<DesktopShell*>(user_data);
  g_dbus_method_invocation_return_value(invocation, nullptr);
  if (g_strcmp0(method, "Activate") == 0 ||
      g_strcmp0(method, "SecondaryActivate") == 0) {
    activate(self);
  } else if (g_strcmp0(method, "ProvideXdgActivationToken") == 0) {
    g_free(self->activation_token);
    g_variant_get(parameters, "(s)", &self->activation_token);
  }
  // ContextMenu and Scroll: the host shows the dbusmenu itself.
}

// --- com.canonical.dbusmenu ---

static gboolean menu_item_exists(gint id) {
  return id >= kMenuRoot && id <= kMenuQuit;
}

static GVariant* menu_item_properties(gint id) {
  GVariantBuilder b;
  g_variant_builder_init(&b, G_VARIANT_TYPE("a{sv}"));
  switch (id) {
    case kMenuRoot:
      g_variant_builder_add(&b, "{sv}", "children-display",
                            g_variant_new_string("submenu"));
      break;
    case kMenuOpen:
      g_variant_builder_add(&b, "{sv}", "label",
                            g_variant_new_string("Open FamChat"));
      break;
    case kMenuSeparator:
      g_variant_builder_add(&b, "{sv}", "type",
                            g_variant_new_string("separator"));
      break;
    case kMenuQuit:
      g_variant_builder_add(&b, "{sv}", "label", g_variant_new_string("Quit"));
      break;
  }
  return g_variant_builder_end(&b);
}

static GVariant* menu_layout(gint id, gint depth) {
  GVariantBuilder children;
  g_variant_builder_init(&children, G_VARIANT_TYPE("av"));
  if (id == kMenuRoot && depth != 0) {
    for (gint child = kMenuOpen; child <= kMenuQuit; child++) {
      g_variant_builder_add(&children, "v", menu_layout(child, depth - 1));
    }
  }
  return g_variant_new("(i@a{sv}av)", id, menu_item_properties(id),
                       &children);
}

static void menu_event(DesktopShell* self, gint id, const gchar* event) {
  if (g_strcmp0(event, "clicked") != 0) return;
  if (id == kMenuOpen) {
    activate(self);
  } else if (id == kMenuQuit && self->callbacks.quit != nullptr) {
    self->callbacks.quit(self->callbacks.user_data);
  }
}

static GVariant* menu_get_property(GDBusConnection* bus, const gchar* sender,
                                   const gchar* path, const gchar* interface,
                                   const gchar* name, GError** error,
                                   gpointer user_data) {
  if (g_strcmp0(name, "Version") == 0) return g_variant_new_uint32(3);
  if (g_strcmp0(name, "TextDirection") == 0) return g_variant_new_string("ltr");
  if (g_strcmp0(name, "Status") == 0) return g_variant_new_string("normal");
  if (g_strcmp0(name, "IconThemePath") == 0) {
    return g_variant_new_strv(nullptr, 0);
  }
  g_set_error(error, G_DBUS_ERROR, G_DBUS_ERROR_UNKNOWN_PROPERTY,
              "No property %s", name);
  return nullptr;
}

static void menu_method_call(GDBusConnection* bus, const gchar* sender,
                             const gchar* path, const gchar* interface,
                             const gchar* method, GVariant* parameters,
                             GDBusMethodInvocation* invocation,
                             gpointer user_data) {
  DesktopShell* self = static_cast<DesktopShell*>(user_data);
  if (g_strcmp0(method, "GetLayout") == 0) {
    gint parent = 0, depth = -1;
    g_variant_get(parameters, "(ii@as)", &parent, &depth, nullptr);
    if (!menu_item_exists(parent)) {
      g_dbus_method_invocation_return_error(invocation, G_DBUS_ERROR,
                                            G_DBUS_ERROR_INVALID_ARGS,
                                            "No menu item %d", parent);
      return;
    }
    g_dbus_method_invocation_return_value(
        invocation, g_variant_new("(u@(ia{sv}av))", 1u,
                                  menu_layout(parent, depth)));
  } else if (g_strcmp0(method, "GetGroupProperties") == 0) {
    g_autoptr(GVariant) ids = g_variant_get_child_value(parameters, 0);
    GVariantBuilder b;
    g_variant_builder_init(&b, G_VARIANT_TYPE("a(ia{sv})"));
    gsize n = g_variant_n_children(ids);
    if (n == 0) {
      for (gint id = kMenuRoot; id <= kMenuQuit; id++) {
        g_variant_builder_add(&b, "(i@a{sv})", id, menu_item_properties(id));
      }
    }
    for (gsize i = 0; i < n; i++) {
      gint id = 0;
      g_variant_get_child(ids, i, "i", &id);
      if (menu_item_exists(id)) {
        g_variant_builder_add(&b, "(i@a{sv})", id, menu_item_properties(id));
      }
    }
    g_dbus_method_invocation_return_value(invocation,
                                          g_variant_new("(a(ia{sv}))", &b));
  } else if (g_strcmp0(method, "GetProperty") == 0) {
    gint id = 0;
    const gchar* name = nullptr;
    g_variant_get(parameters, "(i&s)", &id, &name);
    g_autoptr(GVariant) properties =
        menu_item_exists(id) ? g_variant_ref_sink(menu_item_properties(id))
                             : nullptr;
    g_autoptr(GVariant) value =
        properties != nullptr
            ? g_variant_lookup_value(properties, name, nullptr)
            : nullptr;
    if (value == nullptr) {
      g_dbus_method_invocation_return_error(
          invocation, G_DBUS_ERROR, G_DBUS_ERROR_INVALID_ARGS,
          "No property %s on menu item %d", name, id);
      return;
    }
    g_dbus_method_invocation_return_value(invocation,
                                          g_variant_new("(v)", value));
  } else if (g_strcmp0(method, "Event") == 0) {
    gint id = 0;
    g_autofree gchar* event = nullptr;
    g_variant_get(parameters, "(is@vu)", &id, &event, nullptr, nullptr);
    g_dbus_method_invocation_return_value(invocation, nullptr);
    menu_event(self, id, event);
  } else if (g_strcmp0(method, "EventGroup") == 0) {
    g_autoptr(GVariant) events = g_variant_get_child_value(parameters, 0);
    g_dbus_method_invocation_return_value(
        invocation, g_variant_new("(@ai)", g_variant_new_array(
                                               G_VARIANT_TYPE_INT32, nullptr, 0)));
    gsize n = g_variant_n_children(events);
    for (gsize i = 0; i < n; i++) {
      gint id = 0;
      g_autofree gchar* event = nullptr;
      g_variant_get_child(events, i, "(is@vu)", &id, &event, nullptr, nullptr);
      menu_event(self, id, event);
    }
  } else if (g_strcmp0(method, "AboutToShow") == 0) {
    g_dbus_method_invocation_return_value(invocation,
                                          g_variant_new("(b)", FALSE));
  } else if (g_strcmp0(method, "AboutToShowGroup") == 0) {
    g_dbus_method_invocation_return_value(
        invocation,
        g_variant_new("(@ai@ai)",
                      g_variant_new_array(G_VARIANT_TYPE_INT32, nullptr, 0),
                      g_variant_new_array(G_VARIANT_TYPE_INT32, nullptr, 0)));
  } else {
    g_dbus_method_invocation_return_error(invocation, G_DBUS_ERROR,
                                          G_DBUS_ERROR_UNKNOWN_METHOD,
                                          "No method %s", method);
  }
}

// --- com.canonical.Unity.LauncherEntry ---

static GVariant* launcher_properties(DesktopShell* self) {
  GVariantBuilder b;
  g_variant_builder_init(&b, G_VARIANT_TYPE("a{sv}"));
  g_variant_builder_add(&b, "{sv}", "count", g_variant_new_int64(self->count));
  g_variant_builder_add(&b, "{sv}", "count-visible",
                        g_variant_new_boolean(self->count > 0));
  return g_variant_builder_end(&b);
}

static void launcher_method_call(GDBusConnection* bus, const gchar* sender,
                                 const gchar* path, const gchar* interface,
                                 const gchar* method, GVariant* parameters,
                                 GDBusMethodInvocation* invocation,
                                 gpointer user_data) {
  DesktopShell* self = static_cast<DesktopShell*>(user_data);
  g_dbus_method_invocation_return_value(
      invocation,
      g_variant_new("(s@a{sv})", self->app_uri, launcher_properties(self)));
}

// --- Registering the icon with the watcher ---

static void register_done(GObject* source, GAsyncResult* result,
                          gpointer user_data) {
  g_autoptr(GError) error = nullptr;
  g_autoptr(GVariant) reply = g_dbus_connection_call_finish(
      G_DBUS_CONNECTION(source), result, &error);
  (void)reply;  // only the error matters; the reply is freed on return
  if (g_error_matches(error, G_IO_ERROR, G_IO_ERROR_CANCELLED)) return;
  DesktopShell* self = static_cast<DesktopShell*>(user_data);
  if (error != nullptr) {
    g_warning("Tray icon not registered: %s", error->message);
    return;
  }
  // Hidden again meanwhile: the name is gone, and the icon with it.
  self->shown = self->name_owner != 0;
}

static void name_acquired(GDBusConnection* bus, const gchar* name,
                          gpointer user_data) {
  DesktopShell* self = static_cast<DesktopShell*>(user_data);
  g_dbus_connection_call(bus, kWatcherName, "/StatusNotifierWatcher",
                         kWatcherName, "RegisterStatusNotifierItem",
                         g_variant_new("(s)", name), nullptr,
                         G_DBUS_CALL_FLAGS_NONE, -1, self->cancellable,
                         register_done, self);
}

static void name_lost(GDBusConnection* bus, const gchar* name,
                      gpointer user_data) {
  DesktopShell* self = static_cast<DesktopShell*>(user_data);
  self->shown = FALSE;
}

static void hide_item(DesktopShell* self) {
  if (self->name_owner != 0) {
    g_bus_unown_name(self->name_owner);
    self->name_owner = 0;
  }
  self->shown = FALSE;
}

static void show_item(DesktopShell* self) {
  if (self->bus == nullptr || !self->available || self->name_owner != 0) {
    return;
  }
  // A new name each time, so a watcher still dropping the old one can't drop
  // this one.
  g_autofree gchar* name =
      g_strdup_printf("org.kde.StatusNotifierItem-%d-%u",
                      static_cast<int>(getpid()), ++self->name_serial);
  self->name_owner = g_bus_own_name_on_connection(
      self->bus, name, G_BUS_NAME_OWNER_FLAGS_DO_NOT_QUEUE, name_acquired,
      name_lost, self, nullptr);
}

static void watcher_appeared(GDBusConnection* bus, const gchar* name,
                             const gchar* owner, gpointer user_data) {
  DesktopShell* self = static_cast<DesktopShell*>(user_data);
  self->available = TRUE;
  // A restarted watcher knows nothing of the icon: register it afresh.
  hide_item(self);
  if (self->want_visible) show_item(self);
  if (self->callbacks.tray_available_changed != nullptr) {
    self->callbacks.tray_available_changed(TRUE, self->callbacks.user_data);
  }
}

static void watcher_vanished(GDBusConnection* bus, const gchar* name,
                             gpointer user_data) {
  DesktopShell* self = static_cast<DesktopShell*>(user_data);
  gboolean was = self->available;
  self->available = FALSE;
  hide_item(self);
  if (was && self->callbacks.tray_available_changed != nullptr) {
    self->callbacks.tray_available_changed(FALSE, self->callbacks.user_data);
  }
}

// --- Public ---

static guint export_object(DesktopShell* self, const gchar* xml,
                           const gchar* path,
                           GDBusInterfaceMethodCallFunc method_call,
                           GDBusInterfaceGetPropertyFunc get_property) {
  g_autoptr(GError) error = nullptr;
  g_autoptr(GDBusNodeInfo) info = g_dbus_node_info_new_for_xml(xml, &error);
  if (info == nullptr) {
    g_warning("Bad D-Bus interface for %s: %s", path, error->message);
    return 0;
  }
  const GDBusInterfaceVTable vtable = {method_call, get_property, nullptr, {}};
  guint id = g_dbus_connection_register_object(
      self->bus, path, info->interfaces[0], &vtable, self, nullptr, &error);
  if (id == 0) {
    g_warning("Couldn't export %s: %s", path, error->message);
  }
  return id;
}

DesktopShell* desktop_shell_new(const gchar* app_id,
                                const DesktopShellCallbacks* callbacks) {
  DesktopShell* self = g_new0(DesktopShell, 1);
  self->callbacks = *callbacks;
  self->app_id = g_strdup(app_id);
  self->app_uri = g_strdup_printf("application://%s.desktop", app_id);
  self->cancellable = g_cancellable_new();

  g_autoptr(GError) error = nullptr;
  self->bus = g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, &error);
  if (self->bus == nullptr) {
    g_warning("No session bus, so no tray icon or launcher count: %s",
              error->message);
    return self;
  }
  self->item_registration = export_object(self, kItemXml, kItemPath,
                                          item_method_call, item_get_property);
  self->menu_registration = export_object(self, kMenuXml, kMenuPath,
                                          menu_method_call, menu_get_property);
  self->launcher_registration = export_object(
      self, kLauncherXml, kLauncherPath, launcher_method_call, nullptr);
  self->watcher_watch = g_bus_watch_name_on_connection(
      self->bus, kWatcherName, G_BUS_NAME_WATCHER_FLAGS_NONE, watcher_appeared,
      watcher_vanished, self, nullptr);
  return self;
}

void desktop_shell_free(DesktopShell* self) {
  if (self == nullptr) return;
  g_cancellable_cancel(self->cancellable);
  hide_item(self);
  if (self->watcher_watch != 0) g_bus_unwatch_name(self->watcher_watch);
  if (self->bus != nullptr) {
    for (guint id : {self->item_registration, self->menu_registration,
                     self->launcher_registration}) {
      if (id != 0) g_dbus_connection_unregister_object(self->bus, id);
    }
  }
  g_clear_object(&self->bus);
  g_clear_object(&self->cancellable);
  g_clear_pointer(&self->pixmaps, g_variant_unref);
  g_free(self->tooltip);
  g_free(self->activation_token);
  g_free(self->app_id);
  g_free(self->app_uri);
  g_free(self);
}

gboolean desktop_shell_tray_available(DesktopShell* self) {
  return self->available;
}

gboolean desktop_shell_tray_shown(DesktopShell* self) { return self->shown; }

void desktop_shell_set_tray(DesktopShell* self, gboolean visible,
                            const gchar* tooltip, GVariant* pixmaps) {
  self->want_visible = visible;
  if (tooltip != nullptr && g_strcmp0(tooltip, self->tooltip) != 0) {
    g_free(self->tooltip);
    self->tooltip = g_strdup(tooltip);
    emit_item_signal(self, "NewToolTip");
  }
  if (pixmaps != nullptr) {
    g_clear_pointer(&self->pixmaps, g_variant_unref);
    self->pixmaps = g_variant_ref_sink(pixmaps);
    emit_item_signal(self, "NewIcon");
  }
  if (visible) {
    show_item(self);
  } else {
    hide_item(self);
  }
}

void desktop_shell_set_count(DesktopShell* self, gint64 count) {
  self->count = count < 0 ? 0 : count;
  if (self->bus == nullptr) return;
  g_dbus_connection_emit_signal(
      self->bus, nullptr, kLauncherPath, kLauncherInterface, "Update",
      g_variant_new("(s@a{sv})", self->app_uri, launcher_properties(self)),
      nullptr);
}
