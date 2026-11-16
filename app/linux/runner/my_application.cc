#include "my_application.h"

#include <flutter_linux/flutter_linux.h>

#include <cstring>

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
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
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
  return map;
}

static gboolean window_state_cb(GtkWidget* widget, GdkEventWindowState* event,
                                gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
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
  } else if (strcmp(method, "close") == 0) {
    gtk_window_close(window);
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

  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));
  gtk_window_set_default_size(window, 1280, 720);
  self->window = window;

  // FamChat draws its own title bar (lib/window/title_bar.dart). A custom
  // title bar that is never shown removes the system one but keeps GTK's
  // client-side frame: the shadow and the resize borders around the window, on
  // Wayland and X11. (Shown, even an empty one takes the theme's title bar
  // height.)
  gtk_window_set_titlebar(window, gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0));
  g_signal_connect(window, "window-state-event", G_CALLBACK(window_state_cb),
                   self);
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
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  g_clear_object(&self->window_channel);
  g_clear_pointer(&self->last_button_press, gdk_event_free);
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
                                     G_APPLICATION_NON_UNIQUE, nullptr));
}
