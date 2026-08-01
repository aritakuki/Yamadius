#include <EGL/egl.h>
#include <GL/gl.h>
#include <cstdio>

int main() {
  EGLDisplay d = eglGetDisplay(EGL_DEFAULT_DISPLAY);
  if (d == EGL_NO_DISPLAY || !eglInitialize(d, nullptr, nullptr)) return 2;
  if (!eglBindAPI(EGL_OPENGL_API)) return 3;
  EGLint attrs[] = {EGL_SURFACE_TYPE,EGL_PBUFFER_BIT,EGL_RENDERABLE_TYPE,EGL_OPENGL_BIT,EGL_NONE};
  EGLConfig config; EGLint count = 0;
  if (!eglChooseConfig(d, attrs, &config, 1, &count) || !count) return 4;
  EGLint size[] = {EGL_WIDTH,16,EGL_HEIGHT,16,EGL_NONE};
  EGLSurface s = eglCreatePbufferSurface(d, config, size);
  EGLContext c = eglCreateContext(d, config, EGL_NO_CONTEXT, nullptr);
  if (s == EGL_NO_SURFACE || c == EGL_NO_CONTEXT || !eglMakeCurrent(d,s,s,c)) return 5;
  std::printf("EGL_VENDOR=%s\nGL_VENDOR=%s\nGL_RENDERER=%s\nGL_VERSION=%s\n",
    eglQueryString(d,EGL_VENDOR), glGetString(GL_VENDOR), glGetString(GL_RENDERER), glGetString(GL_VERSION));
  glBegin(GL_TRIANGLES); glVertex2f(0,0); glVertex2f(1,0); glVertex2f(0,1); glEnd();
  std::printf("FIXED_FUNCTION_GL_ERROR=%u\n", glGetError());
  return 0;
}
