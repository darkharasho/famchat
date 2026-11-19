#include "my_application.h"

#include <flutter_linux/flutter_linux.h>

#include <cstring>

#include "desktop_shell.h"
#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  GtkWindow* window;
  // famchat/window: the in-app title bar's requests
  // (lib/window/window_controls.dart).
  FlMethodChannel* window_channel;
  // The latest mouse press, which window moves and the window menu need.
  GdkEvent* last_button_press;
  // The tray icon and the launcher's unread count (desktop_shell.h).
  DesktopShell* shell;
  // Set from Dart (setCloseToTray): closing hides the window to the tray.
  gboolean close_to_tray;
  // The window is hidden to the tray.
  gboolean hidden;
  // Quitting for real: closing must not hide.
  gboolean quitting;
  // The window's size when neither maximized nor full screen, and whether it is
  // maximized: what window.ini keeps for the next launch.
  gint saved_width;
  gint saved_height;
  gboolean saved_maximized;
  // A pending debounced write of window.ini, or 0.
  guint save_source;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// The window's size across launches, in
// $XDG_CONFIG_HOME/famchat/window.ini. Only the size and the maximized state:
// Wayland doesn't let an app place its window.
static constexpr gint kDefaultWidth = 1280;
static constexpr gint kDefaultHeight = 720;
// Smaller than the minimum (the view's size request) and larger than any
// screen: values outside these are junk.
static constexpr gint kSaneMinWidth = 360;
static constexpr gint kSaneMinHeight = 480;
static constexpr gint kSaneMax = 16384;
static constexpr const gchar* kWindowGroup = "Window";

static gchar* window_ini_path() {
  return g_build_filename(g_get_user_config_dir(), "famchat", "window.ini",
                          nullptr);
}

// Reads window.ini into saved_*, falling back to the defaults; the size is
// clamped to the monitor's work area.
static void load_window_geometry(MyApplication* self) {
  self->saved_width = kDefaultWidth;
  self->saved_height = kDefaultHeight;
  self->saved_maximized = FALSE;

  g_autofree gchar* path = window_ini_path();
  g_autoptr(GKeyFile) file = g_key_file_new();
  if (g_key_file_load_from_file(file, path, G_KEY_FILE_NONE, nullptr)) {
    g_autoptr(GError) width_error = nullptr;
    g_autoptr(GError) height_error = nullptr;
    const gint width =
        g_key_file_get_integer(file, kWindowGroup, "width", &width_error);
    const gint height =
        g_key_file_get_integer(file, kWindowGroup, "height", &height_error);
    if (width_error == nullptr && height_error == nullptr &&
        width >= kSaneMinWidth && width <= kSaneMax &&
        height >= kSaneMinHeight && height <= kSaneMax) {
      self->saved_width = width;
      self->saved_height = height;
    }
    self->saved_maximized =
        g_key_file_get_boolean(file, kWindowGroup, "maximized", nullptr);
  }

  // Never open larger than the screen (a smaller monitor than last time).
  GdkDisplay* display = gdk_display_get_default();
  if (display != nullptr) {
    GdkMonitor* monitor = gdk_display_get_primary_monitor(display);
    if (monitor == nullptr && gdk_display_get_n_monitors(display) > 0) {
      monitor = gdk_display_get_monitor(display, 0);
    }
    if (monitor != nullptr) {
      GdkRectangle area;
      gdk_monitor_get_workarea(monitor, &area);
      if (area.width >= kSaneMinWidth && area.height >= kSaneMinHeight) {
        self->saved_width = MIN(self->saved_width, area.width);
        self->saved_height = MIN(self->saved_height, area.height);
      }
    }
  }
}

static void save_window_geometry(MyApplication* self) {
  if (self->save_source != 0) {
    g_source_remove(self->save_source);
    self->save_source = 0;
  }
  if (self->saved_width <= 0 || self->saved_height <= 0) return;

  g_autofree gchar* path = window_ini_path();
  g_autofree gchar* dir = g_path_get_dirname(path);
  if (g_mkdir_with_parents(dir, 0700) != 0) return;
  g_autoptr(GKeyFile) file = g_key_file_new();
  g_key_file_set_integer(file, kWindowGroup, "width", self->saved_width);
  g_key_file_set_integer(file, kWindowGroup, "height", self->saved_height);
  g_key_file_set_boolean(file, kWindowGroup, "maximized",
                         self->saved_maximized);
  g_autoptr(GError) error = nullptr;
  if (!g_key_file_save_to_file(file, path, &error)) {
    g_warning("Failed to save %s: %s", path, error->message);
  }
}

static gboolean save_window_geometry_cb(gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  self->save_source = 0;
  save_window_geometry(self);
  return G_SOURCE_REMOVE;
}

// Writes window.ini a moment after the last change, not on every step of a
// resize drag.
static void schedule_save_window_geometry(MyApplication* self) {
  if (self->save_source != 0) g_source_remove(self->save_source);
  self->save_source = g_timeout_add(500, save_window_geometry_cb, self);
}

// Whether the window has its own size now, not one the window manager gave it.
static gboolean window_is_floating(GtkWindow* window) {
  GdkWindow* gdk_window = gtk_widget_get_window(GTK_WIDGET(window));
  if (gdk_window == nullptr) return FALSE;
  const GdkWindowState state = gdk_window_get_state(gdk_window);
  return (state & (GDK_WINDOW_STATE_MAXIMIZED | GDK_WINDOW_STATE_FULLSCREEN |
                   GDK_WINDOW_STATE_TILED | GDK_WINDOW_STATE_ICONIFIED)) == 0;
}

// GTK's advice for keeping a window's size: gtk_window_get_size in
// configure-event, gtk_window_set_default_size on the next launch.
static gboolean configure_event_cb(GtkWidget* widget, GdkEventConfigure* event,
                                   gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  GtkWindow* window = GTK_WINDOW(widget);
  if (window_is_floating(window)) {
    gint width = 0;
    gint height = 0;
    gtk_window_get_size(window, &width, &height);
    if (width > 0 && height > 0 &&
        (width != self->saved_width || height != self->saved_height)) {
      self->saved_width = width;
      self->saved_height = height;
      schedule_save_window_geometry(self);
    }
  }
  return FALSE;
}

// Keeps a copy of each mouse press, then lets GTK handle it as usual.
static void record_button_press(GdkEvent* event, gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  if (event->type == GDK_BUTTON_PRESS) {
    g_clear_pointer(&self->last_button_press, gdk_event_free);
    self->last_button_press = gdk_event_copy(event);
  }
  gtk_main_do_event(event);
}

static FlValue* window_state(MyApplication* self) {
  GdkWindow* gdk_window = gtk_widget_get_window(GTK_WIDGET(self->window));
  GdkWindowState state = gdk_window != nullptr
                             ? gdk_window_get_state(gdk_window)
                             : static_cast<GdkWindowState>(0);
  FlValue* map = fl_value_new_map();
  fl_value_set_string_take(
      map, "maximized",
      fl_value_new_bool((state & GDK_WINDOW_STATE_MAXIMIZED) != 0));
  fl_value_set_string_take(
      map, "fullScreen",
      fl_value_new_bool((state & GDK_WINDOW_STATE_FULLSCREEN) != 0));
  fl_value_set_string_take(
      map, "trayAvailable",
      fl_value_new_bool(self->shell != nullptr &&
                        desktop_shell_tray_available(self->shell)));
  fl_value_set_string_take(map, "hidden", fl_value_new_bool(self->hidden));
  return map;
}

static void send_window_state(MyApplication* self) {
  if (self->window_channel == nullptr) return;
  g_autoptr(FlValue) state = window_state(self);
  fl_method_channel_invoke_method(self->window_channel, "stateChanged", state,
                                  nullptr, nullptr, nullptr);
}

// Whether the user can get a hidden window back: through the tray icon.
static gboolean can_hide(MyApplication* self) {
  return self->shell != nullptr && desktop_shell_tray_shown(self->shell);
}

static void hide_window(MyApplication* self) {
  gtk_widget_hide(GTK_WIDGET(self->window));
  self->hidden = TRUE;
  send_window_state(self);
}

static void show_window(MyApplication* self, const gchar* activation_token) {
  GtkWindow* window = self->window;
  if (window == nullptr) return;
  // Lets Wayland compositors give the window focus (xdg-activation).
  if (activation_token != nullptr && *activation_token != '\0') {
    gtk_window_set_startup_id(window, activation_token);
  }
  gtk_widget_show(GTK_WIDGET(window));
  gtk_window_deiconify(window);
  gtk_window_present(window);
  if (self->hidden) {
    self->hidden = FALSE;
    send_window_state(self);
  }
}

static void quit_app(MyApplication* self) {
  self->quitting = TRUE;
  if (self->window != nullptr) {
    // Closes on idle, outside whatever callback asked.
    gtk_window_close(self->window);
  } else {
    g_application_quit(G_APPLICATION(self));
  }
}

// The window manager's close (the title bar is FamChat's own, but Alt+F4 and
// the taskbar's Close come here): hide to the tray when Dart says so and the
// tray icon is up, else close, which quits.
static gboolean delete_event_cb(GtkWidget* widget, GdkEvent* event,
                                gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  save_window_geometry(self);
  if (!self->quitting && self->close_to_tray && can_hide(self)) {
    hide_window(self);
    return TRUE;
  }
  return FALSE;
}

static void shell_activate_cb(const gchar* activation_token,
                              gpointer user_data) {
  show_window(MY_APPLICATION(user_data), activation_token);
}

static void shell_quit_cb(gpointer user_data) {
  quit_app(MY_APPLICATION(user_data));
}

static void shell_tray_available_cb(gboolean available, gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  // The tray went away with the window hidden in it: bring the window back
  // rather than leave it unreachable.
  if (!available && self->hidden) show_window(self, nullptr);
  send_window_state(self);
}

// {visible, tooltip, icons: [{size, pixels (ARGB)}]} from
// lib/window/desktop_badges.dart.
static void set_tray(MyApplication* self, FlValue* args) {
  if (self->shell == nullptr || args == nullptr ||
      fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    return;
  }
  FlValue* visible = fl_value_lookup_string(args, "visible");
  FlValue* tooltip = fl_value_lookup_string(args, "tooltip");
  FlValue* icons = fl_value_lookup_string(args, "icons");
  GVariant* pixmaps = nullptr;
  if (icons != nullptr && fl_value_get_type(icons) == FL_VALUE_TYPE_LIST) {
    GVariantBuilder b;
    g_variant_builder_init(&b, G_VARIANT_TYPE("a(iiay)"));
    for (size_t i = 0; i < fl_value_get_length(icons); i++) {
      FlValue* icon = fl_value_get_list_value(icons, i);
      if (fl_value_get_type(icon) != FL_VALUE_TYPE_MAP) continue;
      FlValue* size = fl_value_lookup_string(icon, "size");
      FlValue* pixels = fl_value_lookup_string(icon, "pixels");
      if (size == nullptr || pixels == nullptr ||
          fl_value_get_type(size) != FL_VALUE_TYPE_INT ||
          fl_value_get_type(pixels) != FL_VALUE_TYPE_UINT8_LIST) {
        continue;
      }
      const int64_t s = fl_value_get_int(size);
      if (s <= 0 ||
          static_cast<int64_t>(fl_value_get_length(pixels)) != s * s * 4) {
        continue;
      }
      g_variant_builder_add(
          &b, "(ii@ay)", static_cast<gint32>(s), static_cast<gint32>(s),
          g_variant_new_fixed_array(G_VARIANT_TYPE_BYTE,
                                    fl_value_get_uint8_list(pixels),
                                    fl_value_get_length(pixels), 1));
    }
    pixmaps = g_variant_builder_end(&b);
  }
  desktop_shell_set_tray(
      self->shell,
      visible != nullptr && fl_value_get_type(visible) == FL_VALUE_TYPE_BOOL &&
          fl_value_get_bool(visible),
      tooltip != nullptr && fl_value_get_type(tooltip) == FL_VALUE_TYPE_STRING
          ? fl_value_get_string(tooltip)
          : nullptr,
      pixmaps);
}

static gboolean window_state_cb(GtkWidget* widget, GdkEventWindowState* event,
                                gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  // Minimizing or full screen leaves the maximized flag as it was.
  if ((event->changed_mask & GDK_WINDOW_STATE_MAXIMIZED) != 0) {
    const gboolean maximized =
        (event->new_window_state & GDK_WINDOW_STATE_MAXIMIZED) != 0;
    if (maximized != self->saved_maximized) {
      self->saved_maximized = maximized;
      schedule_save_window_geometry(self);
    }
  }
  if (self->window_channel != nullptr &&
      (event->changed_mask &
       (GDK_WINDOW_STATE_MAXIMIZED | GDK_WINDOW_STATE_FULLSCREEN)) != 0) {
    g_autoptr(FlValue) state = window_state(self);
    fl_method_channel_invoke_method(self->window_channel, "stateChanged",
                                    state, nullptr, nullptr, nullptr);
  }
  return FALSE;
}

static void window_method_cb(FlMethodChannel* channel, FlMethodCall* call,
                             gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  GtkWindow* window = self->window;
  GdkEvent* press = self->last_button_press;
  const gchar* method = fl_method_call_get_name(call);
  g_autoptr(FlValue) result = nullptr;

  if (strcmp(method, "state") == 0) {
    result = window_state(self);
  } else if (strcmp(method, "startDrag") == 0) {
    if (press != nullptr) {
      gtk_window_begin_move_drag(window, press->button.button,
                                 static_cast<gint>(press->button.x_root),
                                 static_cast<gint>(press->button.y_root),
                                 press->button.time);
      // The window manager has the pointer now, so Flutter would never see
      // the button come up and the title bar would stay pressed. Tell it.
      GdkEvent* release = gdk_event_copy(press);
      release->type = GDK_BUTTON_RELEASE;
      gtk_main_do_event(release);
      gdk_event_free(release);
    }
  } else if (strcmp(method, "toggleMaximize") == 0) {
    if (gtk_window_is_maximized(window)) {
      gtk_window_unmaximize(window);
    } else {
      gtk_window_maximize(window);
    }
  } else if (strcmp(method, "minimize") == 0) {
    gtk_window_iconify(window);
  } else if (strcmp(method, "hide") == 0) {
    // Never hide without a tray icon to come back through.
    if (can_hide(self)) {
      hide_window(self);
    } else {
      quit_app(self);
    }
  } else if (strcmp(method, "show") == 0) {
    show_window(self, nullptr);
  } else if (strcmp(method, "quit") == 0) {
    quit_app(self);
  } else if (strcmp(method, "setCloseToTray") == 0) {
    FlValue* on = fl_method_call_get_args(call);
    self->close_to_tray = on != nullptr &&
                          fl_value_get_type(on) == FL_VALUE_TYPE_BOOL &&
                          fl_value_get_bool(on);
  } else if (strcmp(method, "setTray") == 0) {
    set_tray(self, fl_method_call_get_args(call));
  } else if (strcmp(method, "setBadge") == 0) {
    FlValue* args = fl_method_call_get_args(call);
    FlValue* count =
        args != nullptr && fl_value_get_type(args) == FL_VALUE_TYPE_MAP
            ? fl_value_lookup_string(args, "count")
            : nullptr;
    if (self->shell != nullptr && count != nullptr &&
        fl_value_get_type(count) == FL_VALUE_TYPE_INT) {
      desktop_shell_set_count(self->shell, fl_value_get_int(count));
    }
  } else if (strcmp(method, "showMenu") == 0) {
    GdkWindow* gdk_window = gtk_widget_get_window(GTK_WIDGET(window));
    if (press != nullptr && gdk_window != nullptr) {
      gdk_window_show_window_menu(gdk_window, press);
    }
  } else {
    fl_method_call_respond_not_implemented(call, nullptr);
    return;
  }
  fl_method_call_respond_success(call, result, nullptr);
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);

  // FamChat runs once: launching it again (from the menu or the dock, say)
  // brings back the running one's window, which may be hidden in the tray.
  if (self->window != nullptr) {
    show_window(self, nullptr);
    return;
  }

  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));
  // The size (and maximized state) it had last time, before it is shown, so
  // it opens that way.
  load_window_geometry(self);
  gtk_window_set_default_size(window, self->saved_width, self->saved_height);
  if (self->saved_maximized) gtk_window_maximize(window);
  self->window = window;

  // FamChat draws its own title bar (lib/window/title_bar.dart). A custom
  // title bar that is never shown removes the system one but keeps GTK's
  // client-side frame: the shadow and the resize borders around the window, on
  // Wayland and X11. (Shown, even an empty one takes the theme's title bar
  // height.)
  gtk_window_set_titlebar(window, gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0));
  g_signal_connect(window, "window-state-event", G_CALLBACK(window_state_cb),
                   self);
  g_signal_connect(window, "delete-event", G_CALLBACK(delete_event_cb), self);
  g_signal_connect(window, "configure-event", G_CALLBACK(configure_event_cb),
                   self);
  const DesktopShellCallbacks shell_callbacks = {
      shell_activate_cb, shell_quit_cb, shell_tray_available_cb, self};
  self->shell = desktop_shell_new(APPLICATION_ID, &shell_callbacks);
  gdk_event_handler_set(record_button_press, self, nullptr);

  gtk_window_set_title(window, "FamChat");

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  // The smallest window the phone layout still fits in.
  gtk_widget_set_size_request(GTK_WIDGET(view), 380, 500);
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  self->window_channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)),
      "famchat/window", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(self->window_channel,
                                            window_method_cb, self, nullptr);

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);

  // A resize still waiting on its debounced write.
  if (self->save_source != 0) save_window_geometry(self);

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_handle_id(&self->save_source, g_source_remove);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  g_clear_object(&self->window_channel);
  g_clear_pointer(&self->last_button_press, gdk_event_free);
  g_clear_pointer(&self->shell, desktop_shell_free);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     // Unique: a second launch activates
                                     // this one (my_application_activate).
                                     static_cast<GApplicationFlags>(0),
                                     nullptr));
}
