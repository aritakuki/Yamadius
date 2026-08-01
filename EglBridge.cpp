#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GL/gl.h>

#include <cstddef>
#include <cstring>
#include <cstdio>
#include <cstdlib>
#include <vector>

#include <jpeglib.h>

namespace {
EGLDisplay display = EGL_NO_DISPLAY;
EGLSurface surface = EGL_NO_SURFACE;
EGLContext context = EGL_NO_CONTEXT;
int frameWidth = 0;
int frameHeight = 0;

EGLDisplay nvidiaDisplay() {
  auto queryDevices = reinterpret_cast<PFNEGLQUERYDEVICESEXTPROC>(
      eglGetProcAddress("eglQueryDevicesEXT"));
  auto queryDeviceString = reinterpret_cast<PFNEGLQUERYDEVICESTRINGEXTPROC>(
      eglGetProcAddress("eglQueryDeviceStringEXT"));
  auto getPlatformDisplay = reinterpret_cast<PFNEGLGETPLATFORMDISPLAYEXTPROC>(
      eglGetProcAddress("eglGetPlatformDisplayEXT"));
  if (!queryDevices || !getPlatformDisplay) return EGL_NO_DISPLAY;

  EGLDeviceEXT devices[16];
  EGLint count = 0;
  if (!queryDevices(16, devices, &count) || count == 0) return EGL_NO_DISPLAY;
  EGLDeviceEXT selected = EGL_NO_DEVICE_EXT;
  for (EGLint i = 0; queryDeviceString && i < count; ++i) {
    const char* vendor = queryDeviceString(devices[i], EGL_VENDOR);
    if (vendor && std::strstr(vendor, "NVIDIA")) selected = devices[i];
  }
  // Colab's NVIDIA 580 driver may not expose optional device-name strings.
  // The runner supplies an NVIDIA-only GLVND vendor JSON, so its sole EGL
  // device is still unambiguously the Tesla GPU.
  if (selected == EGL_NO_DEVICE_EXT && count == 1) selected = devices[0];
  if (selected == EGL_NO_DEVICE_EXT) return EGL_NO_DISPLAY;
  return getPlatformDisplay(EGL_PLATFORM_DEVICE_EXT, selected, nullptr);
}
}

extern "C" int initEglRenderer(int width, int height) {
  display = nvidiaDisplay();
  if (display == EGL_NO_DISPLAY || !eglInitialize(display, nullptr, nullptr)) return 0;
  if (!eglBindAPI(EGL_OPENGL_API)) return 0;
  const EGLint configAttributes[] = {
      EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_RENDERABLE_TYPE, EGL_OPENGL_BIT,
      EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_NONE};
  EGLConfig config;
  EGLint count = 0;
  if (!eglChooseConfig(display, configAttributes, &config, 1, &count) || count == 0) return 0;
  const EGLint pbufferAttributes[] = {EGL_WIDTH, width, EGL_HEIGHT, height, EGL_NONE};
  surface = eglCreatePbufferSurface(display, config, pbufferAttributes);
  context = eglCreateContext(display, config, EGL_NO_CONTEXT, nullptr);
  if (surface == EGL_NO_SURFACE || context == EGL_NO_CONTEXT ||
      !eglMakeCurrent(display, surface, surface, context)) return 0;
  frameWidth = width;
  frameHeight = height;
  return 1;
}

extern "C" int saveEglFrame(const char* filename) {
  if (context == EGL_NO_CONTEXT) return 0;
  std::vector<unsigned char> rgb(static_cast<size_t>(frameWidth) * frameHeight * 3);
  glPixelStorei(GL_PACK_ALIGNMENT, 1);
  glReadPixels(0, 0, frameWidth, frameHeight, GL_RGB, GL_UNSIGNED_BYTE, rgb.data());

  // EGL pbuffers are allowed to expose a front or back color buffer.  The
  // game renders to the default buffer, while glReadPixels reads the current
  // read buffer.  Prefer that normal path, but when it is completely black,
  // also inspect GL_BACK and use it if it contains the rendered frame.
  const auto energy = [](const std::vector<unsigned char>& pixels) {
    size_t total = 0;
    for (unsigned char value : pixels) total += value;
    return total;
  };
  const size_t normalEnergy = energy(rgb);
  if (normalEnergy == 0) {
    GLint readBuffer = GL_FRONT;
    glGetIntegerv(GL_READ_BUFFER, &readBuffer);
    glReadBuffer(GL_BACK);
    if (glGetError() == GL_NO_ERROR) {
      std::vector<unsigned char> back(rgb.size());
      glReadPixels(0, 0, frameWidth, frameHeight, GL_RGB, GL_UNSIGNED_BYTE, back.data());
      if (glGetError() == GL_NO_ERROR && energy(back) > normalEnergy) rgb.swap(back);
    }
    glReadBuffer(readBuffer);
    glGetError(); // discard an unsupported-buffer error on single-buffer pbuffers
  }
  FILE* file = std::fopen(filename, "wb");
  if (!file) return 0;
  jpeg_compress_struct jpeg{};
  jpeg_error_mgr errors{};
  jpeg.err = jpeg_std_error(&errors);
  jpeg_create_compress(&jpeg);
  jpeg_stdio_dest(&jpeg, file);
  jpeg.image_width = frameWidth;
  jpeg.image_height = frameHeight;
  jpeg.input_components = 3;
  jpeg.in_color_space = JCS_RGB;
  jpeg_set_defaults(&jpeg);
  jpeg_set_quality(&jpeg, 85, TRUE);
  jpeg_start_compress(&jpeg, TRUE);
  while (jpeg.next_scanline < jpeg.image_height) {
    JSAMPROW row = rgb.data() + static_cast<size_t>(frameHeight - 1 - jpeg.next_scanline) * frameWidth * 3;
    jpeg_write_scanlines(&jpeg, &row, 1);
  }
  jpeg_finish_compress(&jpeg);
  jpeg_destroy_compress(&jpeg);
  std::fclose(file);
  return 1;
}

extern "C" void presentMonadiusFrame() {
  const char* filename = std::getenv("MONADIUS_FRAME_FILE");
  if (context != EGL_NO_CONTEXT && filename && *filename) saveEglFrame(filename);
}

extern "C" void finishEglRenderer() {
  if (display != EGL_NO_DISPLAY) {
    eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    if (context != EGL_NO_CONTEXT) eglDestroyContext(display, context);
    if (surface != EGL_NO_SURFACE) eglDestroySurface(display, surface);
    eglTerminate(display);
  }
  display = EGL_NO_DISPLAY; surface = EGL_NO_SURFACE; context = EGL_NO_CONTEXT;
}
