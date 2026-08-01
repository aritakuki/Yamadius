#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GL/gl.h>
#include <cstring>
#include <cstdio>

int main() {
  // Do not use EGL_DEFAULT_DISPLAY: on a headless VM it may select Mesa's
  // software renderer.  Ask EGL for the physical devices and explicitly
  // construct the display belonging to NVIDIA instead.
  auto queryDevices = reinterpret_cast<PFNEGLQUERYDEVICESEXTPROC>(
      eglGetProcAddress("eglQueryDevicesEXT"));
  auto queryDeviceString = reinterpret_cast<PFNEGLQUERYDEVICESTRINGEXTPROC>(
      eglGetProcAddress("eglQueryDeviceStringEXT"));
  auto getPlatformDisplay = reinterpret_cast<PFNEGLGETPLATFORMDISPLAYEXTPROC>(
      eglGetProcAddress("eglGetPlatformDisplayEXT"));
  if (!queryDevices || !queryDeviceString || !getPlatformDisplay) {
    std::fprintf(stderr, "Required EGL device extensions are unavailable\n");
    return 2;
  }

  EGLDeviceEXT devices[16];
  EGLint deviceCount = 0;
  if (!queryDevices(16, devices, &deviceCount) || deviceCount == 0) {
    std::fprintf(stderr, "No EGL devices were enumerated\n");
    return 3;
  }

  EGLDeviceEXT nvidia = nullptr;
  for (EGLint i = 0; i < deviceCount; ++i) {
    const char* vendor = queryDeviceString(devices[i], EGL_VENDOR);
    const char* renderer = queryDeviceString(devices[i], EGL_RENDERER_EXT);
    std::printf("EGL_DEVICE[%d]_VENDOR=%s\nEGL_DEVICE[%d]_RENDERER=%s\n", i,
      vendor ? vendor : "(unknown)", i, renderer ? renderer : "(unknown)");
    if (vendor && std::strstr(vendor, "NVIDIA")) nvidia = devices[i];
  }
  if (!nvidia) {
    std::fprintf(stderr, "NVIDIA EGL device was not enumerated\n");
    return 4;
  }

  EGLDisplay d = getPlatformDisplay(EGL_PLATFORM_DEVICE_EXT, nvidia, nullptr);
  if (d == EGL_NO_DISPLAY || !eglInitialize(d, nullptr, nullptr)) return 5;
  if (!eglBindAPI(EGL_OPENGL_API)) return 3;
  EGLint attrs[] = {EGL_SURFACE_TYPE,EGL_PBUFFER_BIT,EGL_RENDERABLE_TYPE,EGL_OPENGL_BIT,EGL_NONE};
  EGLConfig config; EGLint count = 0;
  if (!eglChooseConfig(d, attrs, &config, 1, &count) || !count) return 6;
  EGLint size[] = {EGL_WIDTH,16,EGL_HEIGHT,16,EGL_NONE};
  EGLSurface s = eglCreatePbufferSurface(d, config, size);
  EGLContext c = eglCreateContext(d, config, EGL_NO_CONTEXT, nullptr);
  if (s == EGL_NO_SURFACE || c == EGL_NO_CONTEXT || !eglMakeCurrent(d,s,s,c)) return 7;
  std::printf("EGL_VENDOR=%s\nGL_VENDOR=%s\nGL_RENDERER=%s\nGL_VERSION=%s\n",
    eglQueryString(d,EGL_VENDOR), glGetString(GL_VENDOR), glGetString(GL_RENDERER), glGetString(GL_VERSION));
  glBegin(GL_TRIANGLES); glVertex2f(0,0); glVertex2f(1,0); glVertex2f(0,1); glEnd();
  const GLenum error = glGetError();
  std::printf("FIXED_FUNCTION_GL_ERROR=%u\n", error);
  return error == GL_NO_ERROR ? 0 : 8;
}
