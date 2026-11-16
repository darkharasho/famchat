#include <stdlib.h>
#include <unistd.h>

#include "my_application.h"

// Flutter 3.50.0 draws the window into its bottom-left quarter when it
// composites without glBlitFramebuffer, which it does on the NVIDIA driver
// (flutter/flutter#196083, cherry-pick #196418). Until a fixed Flutter ships,
// render through Mesa there (the integrated GPU, or llvmpipe), or Flutter's
// software renderer if Mesa's EGL isn't installed. Remove once on a fixed
// Flutter. Setting either variable yourself overrides this.
static void avoid_nvidia_compositing_bug() {
  if (access("/proc/driver/nvidia/version", F_OK) != 0 ||
      getenv("__EGL_VENDOR_LIBRARY_FILENAMES") != nullptr ||
      getenv("FLUTTER_LINUX_RENDERER") != nullptr) {
    return;
  }
  const char* mesa_vendors[] = {
      "/usr/share/glvnd/egl_vendor.d/50_mesa.json",
      "/etc/glvnd/egl_vendor.d/50_mesa.json",
  };
  for (const char* path : mesa_vendors) {
    if (access(path, R_OK) == 0) {
      setenv("__EGL_VENDOR_LIBRARY_FILENAMES", path, 0);
      return;
    }
  }
  setenv("FLUTTER_LINUX_RENDERER", "software", 0);
}

int main(int argc, char** argv) {
  avoid_nvidia_compositing_bug();
  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
