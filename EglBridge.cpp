#include <EGL/egl.h>
#include <EGL/eglext.h>

#define GL_GLEXT_PROTOTYPES
#include <GL/gl.h>
#include <GL/glext.h>

#include <array>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include <jpeglib.h>

namespace {
EGLDisplay display = EGL_NO_DISPLAY;
EGLSurface surface = EGL_NO_SURFACE;
EGLContext context = EGL_NO_CONTEXT;
int frameWidth = 0;
int frameHeight = 0;
size_t frameBytes = 0;

// A GPU readback is submitted into one PBO while previous PBOs are still in
// flight.  presentMonadiusFrame never waits for a fence: if the GPU or browser
// transport is behind, only capture frames are skipped; the Haskell game loop
// continues to update and render every frame.
constexpr size_t kReadbackSlotCount = 3;
struct ReadbackSlot {
  GLuint buffer = 0;
  GLsync fence = nullptr;
  uint64_t serial = 0;
};
std::array<ReadbackSlot, kReadbackSlotCount> readbackSlots{};
uint64_t nextReadbackSerial = 1;
bool captureBufferVerified = false;
bool captureFromBackBuffer = false;

// JPEG compression and atomic file publication are CPU/file work.  Keep one
// replaceable pending frame so this worker can never build an unbounded queue
// or slow down gameplay when Colab networking is congested.
std::mutex encoderMutex;
std::condition_variable encoderReady;
std::vector<unsigned char> pendingFrame;
std::vector<std::vector<unsigned char>> recycledFrames;
bool pendingFrameAvailable = false;
bool encoderStopping = false;
std::thread encoderThread;
std::string frameFilename;

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
  // Colab's NVIDIA driver may not expose optional device-name strings.  The
  // runner supplies an NVIDIA-only GLVND vendor JSON, so its sole EGL device
  // is still unambiguously the Tesla GPU.
  if (selected == EGL_NO_DEVICE_EXT && count == 1) selected = devices[0];
  if (selected == EGL_NO_DEVICE_EXT) return EGL_NO_DISPLAY;
  return getPlatformDisplay(EGL_PLATFORM_DEVICE_EXT, selected, nullptr);
}

bool writeJpeg(const std::vector<unsigned char>& rgb,
               const std::string& filename) {
  if (rgb.size() != frameBytes || filename.empty()) return false;
  const std::string temporaryFilename = filename + ".tmp";
  FILE* file = std::fopen(temporaryFilename.c_str(), "wb");
  if (!file) return false;

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
  jpeg_set_quality(&jpeg, 80, TRUE);
  jpeg_start_compress(&jpeg, TRUE);
  while (jpeg.next_scanline < jpeg.image_height) {
    // OpenGL's origin is bottom-left; JPEG scanlines start at the top.
    JSAMPROW row = const_cast<JSAMPROW>(
        rgb.data() + static_cast<size_t>(frameHeight - 1 - jpeg.next_scanline) *
                         frameWidth * 3);
    jpeg_write_scanlines(&jpeg, &row, 1);
  }
  jpeg_finish_compress(&jpeg);
  jpeg_destroy_compress(&jpeg);
  std::fclose(file);
  if (std::rename(temporaryFilename.c_str(), filename.c_str()) != 0) {
    std::remove(temporaryFilename.c_str());
    return false;
  }
  return true;
}

void encodeFrames() {
  for (;;) {
    std::vector<unsigned char> frame;
    {
      std::unique_lock<std::mutex> lock(encoderMutex);
      encoderReady.wait(lock, [] { return encoderStopping || pendingFrameAvailable; });
      if (encoderStopping && !pendingFrameAvailable) return;
      frame.swap(pendingFrame);
      pendingFrameAvailable = false;
    }
    writeJpeg(frame, frameFilename);
    {
      std::lock_guard<std::mutex> lock(encoderMutex);
      if (recycledFrames.size() < kReadbackSlotCount + 1) {
        recycledFrames.emplace_back(std::move(frame));
      }
    }
  }
}

std::vector<unsigned char> acquireFrameBuffer() {
  std::vector<unsigned char> frame;
  {
    std::lock_guard<std::mutex> lock(encoderMutex);
    if (!recycledFrames.empty()) {
      frame = std::move(recycledFrames.back());
      recycledFrames.pop_back();
    }
  }
  frame.resize(frameBytes);
  return frame;
}

void queueLatestFrame(std::vector<unsigned char>&& frame) {
  {
    std::lock_guard<std::mutex> lock(encoderMutex);
    if (pendingFrameAvailable &&
        recycledFrames.size() < kReadbackSlotCount + 1) {
      recycledFrames.emplace_back(std::move(pendingFrame));
    }
    pendingFrame = std::move(frame);
    pendingFrameAvailable = true;
  }
  encoderReady.notify_one();
}

void releaseReadback(ReadbackSlot& slot) {
  if (slot.fence != nullptr) glDeleteSync(slot.fence);
  slot.fence = nullptr;
  slot.serial = 0;
}

void harvestNewestCompletedReadback() {
  std::array<bool, kReadbackSlotCount> completed{};
  ReadbackSlot* newest = nullptr;
  for (size_t i = 0; i < readbackSlots.size(); ++i) {
    ReadbackSlot& slot = readbackSlots[i];
    if (slot.fence == nullptr) continue;
    const GLenum result = glClientWaitSync(slot.fence, 0, 0);
    if (result == GL_ALREADY_SIGNALED || result == GL_CONDITION_SATISFIED) {
      completed[i] = true;
      if (newest == nullptr || slot.serial > newest->serial) newest = &slot;
    } else if (result == GL_WAIT_FAILED) {
      releaseReadback(slot);
    }
  }

  for (size_t i = 0; i < readbackSlots.size(); ++i) {
    ReadbackSlot& slot = readbackSlots[i];
    if (!completed[i]) continue;
    if (&slot == newest) {
      glBindBuffer(GL_PIXEL_PACK_BUFFER, slot.buffer);
      const void* mapped =
          glMapBufferRange(GL_PIXEL_PACK_BUFFER, 0, frameBytes, GL_MAP_READ_BIT);
      if (mapped != nullptr) {
        std::vector<unsigned char> frame = acquireFrameBuffer();
        std::memcpy(frame.data(), mapped, frameBytes);
        glUnmapBuffer(GL_PIXEL_PACK_BUFFER);
        bool publish = true;
        if (!captureBufferVerified) {
          bool hasVisiblePixel = false;
          for (const unsigned char value : frame) {
            if (value != 0) {
              hasVisiblePixel = true;
              break;
            }
          }
          if (hasVisiblePixel || captureFromBackBuffer) {
            captureBufferVerified = true;
          } else {
            // Preserve the old synchronous bridge's NVIDIA pbuffer fallback,
            // but perform the full-frame check only once during startup.
            captureFromBackBuffer = true;
            publish = false;
          }
        }
        if (publish) queueLatestFrame(std::move(frame));
      }
      glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
    }
    releaseReadback(slot);
  }
}

void submitReadback() {
  for (ReadbackSlot& slot : readbackSlots) {
    if (slot.fence != nullptr) continue;
    glBindBuffer(GL_PIXEL_PACK_BUFFER, slot.buffer);
    glPixelStorei(GL_PACK_ALIGNMENT, 1);
    GLint previousReadBuffer = GL_FRONT;
    if (captureFromBackBuffer) {
      glGetIntegerv(GL_READ_BUFFER, &previousReadBuffer);
      glReadBuffer(GL_BACK);
    }
    glReadPixels(0, 0, frameWidth, frameHeight, GL_RGB, GL_UNSIGNED_BYTE,
                 nullptr);
    if (captureFromBackBuffer) glReadBuffer(previousReadBuffer);
    slot.fence = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
    slot.serial = nextReadbackSerial++;
    glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
    glFlush();
    return;
  }
}
}  // namespace

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
  frameBytes = static_cast<size_t>(width) * height * 3;
  captureBufferVerified = false;
  captureFromBackBuffer = false;
  const char* filename = std::getenv("MONADIUS_FRAME_FILE");
  if (filename != nullptr && *filename != '\0') {
    frameFilename = filename;
    GLuint buffers[kReadbackSlotCount]{};
    glGenBuffers(static_cast<GLsizei>(kReadbackSlotCount), buffers);
    for (size_t i = 0; i < readbackSlots.size(); ++i) {
      readbackSlots[i].buffer = buffers[i];
      glBindBuffer(GL_PIXEL_PACK_BUFFER, buffers[i]);
      glBufferData(GL_PIXEL_PACK_BUFFER, frameBytes, nullptr, GL_STREAM_READ);
    }
    glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
    encoderStopping = false;
    encoderThread = std::thread(encodeFrames);
  }
  return 1;
}

// Synchronous helper retained for diagnostics.  Normal Colab gameplay uses
// presentMonadiusFrame's PBO/worker path below.
extern "C" int saveEglFrame(const char* filename) {
  if (context == EGL_NO_CONTEXT || filename == nullptr) return 0;
  std::vector<unsigned char> rgb(frameBytes);
  glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
  glPixelStorei(GL_PACK_ALIGNMENT, 1);
  glReadPixels(0, 0, frameWidth, frameHeight, GL_RGB, GL_UNSIGNED_BYTE,
               rgb.data());
  return writeJpeg(rgb, filename) ? 1 : 0;
}

extern "C" void presentMonadiusFrame() {
  if (context == EGL_NO_CONTEXT || !encoderThread.joinable()) return;
  harvestNewestCompletedReadback();
  submitReadback();
}

extern "C" void finishEglRenderer() {
  if (context != EGL_NO_CONTEXT) {
    // Discard in-flight capture work.  Gameplay frames have already rendered;
    // shutdown must not wait on GPU readback.
    for (ReadbackSlot& slot : readbackSlots) releaseReadback(slot);
    GLuint buffers[kReadbackSlotCount]{};
    for (size_t i = 0; i < readbackSlots.size(); ++i) {
      buffers[i] = readbackSlots[i].buffer;
      readbackSlots[i].buffer = 0;
    }
    glDeleteBuffers(static_cast<GLsizei>(kReadbackSlotCount), buffers);
  }
  if (encoderThread.joinable()) {
    {
      std::lock_guard<std::mutex> lock(encoderMutex);
      encoderStopping = true;
    }
    encoderReady.notify_one();
    encoderThread.join();
  }
  if (display != EGL_NO_DISPLAY) {
    eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    if (context != EGL_NO_CONTEXT) eglDestroyContext(display, context);
    if (surface != EGL_NO_SURFACE) eglDestroySurface(display, surface);
    eglTerminate(display);
  }
  pendingFrame.clear();
  recycledFrames.clear();
  pendingFrameAvailable = false;
  frameFilename.clear();
  display = EGL_NO_DISPLAY;
  surface = EGL_NO_SURFACE;
  context = EGL_NO_CONTEXT;
}
