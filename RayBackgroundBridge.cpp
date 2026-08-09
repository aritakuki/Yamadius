#include <dlfcn.h>

#define GL_GLEXT_PROTOTYPES
#include <GL/gl.h>
#include <GL/glext.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <exception>
#include <limits>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include <unistd.h>

extern char** environ;

// A callable SBCL core initializes this variable with the Lisp entry point.
// Only this variable and the three callbacks below are exported dynamically;
// exporting every GHC symbol causes ELF symbol interposition with libsbcl.
extern "C" {
void (*monadius_lisp_ray_background_run)(int, int) = nullptr;
}

namespace {
std::mutex frameMutex;
std::array<std::vector<unsigned char>, 2> frameBuffers;
int frontBufferIndex = 0;
std::atomic<uint64_t> publishedGeneration{0};
uint64_t uploadedGeneration = 0;
uint64_t reportedUploadFailureGeneration = 0;

int backgroundWidth = 0;
int backgroundHeight = 0;
GLuint backgroundTexture = 0;
bool backgroundEnabled = false;
bool backgroundInitialized = false;

std::atomic<bool> stopRequested{false};
std::thread lispWorker;

void* sbclRuntime = nullptr;
std::vector<std::string> sbclArgumentStorage;
std::vector<char*> sbclArguments;

bool enabledByEnvironment() {
  const char* value = std::getenv("MONADIUS_RAY_BACKGROUND");
  if (value == nullptr || *value == '\0') return false;
  return std::string(value) != "0" && std::string(value) != "false" &&
         std::string(value) != "FALSE";
}

int positiveEnvironmentInteger(const char* name, int fallback) {
  const char* text = std::getenv(name);
  if (text == nullptr || *text == '\0') return fallback;
  char* end = nullptr;
  const long value = std::strtol(text, &end, 10);
  if (*end != '\0' || value <= 0 || value > 8192) {
    std::fprintf(stderr, "%s must be an integer from 1 through 8192; using %d.\n",
                 name, fallback);
    return fallback;
  }
  return static_cast<int>(value);
}

const char* environmentOrDefault(const char* name, const char* fallback) {
  const char* value = std::getenv(name);
  return value != nullptr && *value != '\0' ? value : fallback;
}

unsigned char byteChannel(float value) {
  if (!std::isfinite(value)) return 0;
  value = std::max(0.0f, std::min(1.0f, value));
  return static_cast<unsigned char>(std::lround(value * 255.0f));
}

void fillOpaqueBlack(std::vector<unsigned char>& pixels, size_t pixelCount) {
  pixels.assign(pixelCount * 4, 0);
  for (size_t pixel = 0; pixel < pixelCount; ++pixel) {
    pixels[pixel * 4 + 3] = 255;
  }
}

void deleteBackgroundTexture() {
  if (backgroundTexture != 0) {
    glDeleteTextures(1, &backgroundTexture);
    backgroundTexture = 0;
  }
}

bool createBackgroundTexture() {
  GLint previousActiveTexture = GL_TEXTURE0;
  GLint previousTexture = 0;
  GLint previousUnpackAlignment = 4;
  GLint previousUnpackBuffer = 0;
  glGetIntegerv(GL_ACTIVE_TEXTURE, &previousActiveTexture);
  glActiveTexture(GL_TEXTURE0);
  glGetIntegerv(GL_TEXTURE_BINDING_2D, &previousTexture);
  glGetIntegerv(GL_UNPACK_ALIGNMENT, &previousUnpackAlignment);
  glGetIntegerv(GL_PIXEL_UNPACK_BUFFER_BINDING, &previousUnpackBuffer);
  while (glGetError() != GL_NO_ERROR) {
  }

  glGenTextures(1, &backgroundTexture);
  if (backgroundTexture == 0) {
    glActiveTexture(previousActiveTexture);
    return false;
  }
  glBindTexture(GL_TEXTURE_2D, backgroundTexture);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
  glBindBuffer(GL_PIXEL_UNPACK_BUFFER, 0);
  glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, backgroundWidth,
               backgroundHeight, 0, GL_RGBA, GL_UNSIGNED_BYTE,
               frameBuffers[frontBufferIndex].data());

  const GLenum error = glGetError();
  glPixelStorei(GL_UNPACK_ALIGNMENT, previousUnpackAlignment);
  glBindBuffer(GL_PIXEL_UNPACK_BUFFER,
               static_cast<GLuint>(previousUnpackBuffer));
  glBindTexture(GL_TEXTURE_2D, static_cast<GLuint>(previousTexture));
  glActiveTexture(previousActiveTexture);
  if (error != GL_NO_ERROR) {
    std::fprintf(stderr,
                 "Could not allocate the live ray background texture (GL 0x%x).\n",
                 error);
    deleteBackgroundTexture();
    return false;
  }
  return true;
}

bool initializeSbcl() {
  const char* library = environmentOrDefault(
      "MONADIUS_SBCL_LIBRARY",
      "/content/monadius-ray-runtime/lib/libsbcl.so");
  const char* core = environmentOrDefault(
      "MONADIUS_RAY_CORE",
      "/content/monadius-ray-runtime/lib/sbcl/monadius-ray-background.core");
  if (access(library, R_OK) != 0) {
    std::fprintf(stderr, "Live ray background SBCL library not found: %s\n",
                 library);
    return false;
  }
  if (access(core, R_OK) != 0) {
    std::fprintf(stderr, "Live ray background Lisp core not found: %s\n", core);
    return false;
  }

  sbclRuntime = dlopen(library, RTLD_NOW | RTLD_GLOBAL);
  if (sbclRuntime == nullptr) {
    std::fprintf(stderr, "Could not load %s: %s\n", library, dlerror());
    return false;
  }

  using InitializeLisp = int (*)(int, char**, char**);
  auto initializeLisp = reinterpret_cast<InitializeLisp>(
      dlsym(sbclRuntime, "initialize_lisp"));
  if (initializeLisp == nullptr) {
    std::fprintf(stderr, "libsbcl does not expose initialize_lisp: %s\n",
                 dlerror());
    return false;
  }

  // SBCL retains its processed argv, so keep both strings and pointers alive
  // for the remainder of the process.
  sbclArgumentStorage = {
      "monadius-embedded-sbcl", "--core", core, "--noinform",
      "--no-userinit", "--no-sysinit", "--disable-debugger"};
  sbclArguments.clear();
  for (const std::string& argument : sbclArgumentStorage) {
    sbclArguments.push_back(const_cast<char*>(argument.c_str()));
  }
  sbclArguments.push_back(nullptr);

  const int result = initializeLisp(
      static_cast<int>(sbclArgumentStorage.size()), sbclArguments.data(),
      environ);
  if (result != 0 || monadius_lisp_ray_background_run == nullptr) {
    std::fputs("The live background core did not publish its Lisp entry point.\n",
               stderr);
    return false;
  }
  return true;
}

void uploadNewestFrameIfNeeded() {
  uint64_t generation = publishedGeneration.load(std::memory_order_acquire);
  if (generation == uploadedGeneration) return;

  std::lock_guard<std::mutex> lock(frameMutex);
  generation = publishedGeneration.load(std::memory_order_relaxed);
  if (generation == uploadedGeneration) return;

  GLint previousTexture = 0;
  GLint previousActiveTexture = GL_TEXTURE0;
  GLint previousUnpackAlignment = 4;
  GLint previousUnpackBuffer = 0;
  glGetIntegerv(GL_ACTIVE_TEXTURE, &previousActiveTexture);
  glActiveTexture(GL_TEXTURE0);
  glGetIntegerv(GL_TEXTURE_BINDING_2D, &previousTexture);
  glGetIntegerv(GL_UNPACK_ALIGNMENT, &previousUnpackAlignment);
  glGetIntegerv(GL_PIXEL_UNPACK_BUFFER_BINDING, &previousUnpackBuffer);
  while (glGetError() != GL_NO_ERROR) {
  }
  glBindTexture(GL_TEXTURE_2D, backgroundTexture);
  glBindBuffer(GL_PIXEL_UNPACK_BUFFER, 0);
  glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
  glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, backgroundWidth,
                  backgroundHeight, GL_RGBA, GL_UNSIGNED_BYTE,
                  frameBuffers[frontBufferIndex].data());
  const GLenum error = glGetError();
  glPixelStorei(GL_UNPACK_ALIGNMENT, previousUnpackAlignment);
  glBindBuffer(GL_PIXEL_UNPACK_BUFFER,
               static_cast<GLuint>(previousUnpackBuffer));
  glBindTexture(GL_TEXTURE_2D, static_cast<GLuint>(previousTexture));
  glActiveTexture(previousActiveTexture);
  if (error == GL_NO_ERROR) {
    if (uploadedGeneration == 1) {
      std::fprintf(stderr,
                   "OpenGL accepted the first complete Lisp background "
                   "(generation %llu).\n",
                   static_cast<unsigned long long>(generation));
    }
    uploadedGeneration = generation;
  } else if (reportedUploadFailureGeneration != generation) {
    std::fprintf(stderr,
                 "Could not upload live ray background generation %llu "
                 "(GL 0x%x); it will be retried.\n",
                 static_cast<unsigned long long>(generation), error);
    reportedUploadFailureGeneration = generation;
  }
}

void drawBackgroundQuad(int x, int y, int width, int height) {
  GLint previousMatrixMode = GL_MODELVIEW;
  GLint previousActiveTexture = GL_TEXTURE0;
  glGetIntegerv(GL_MATRIX_MODE, &previousMatrixMode);
  glGetIntegerv(GL_ACTIVE_TEXTURE, &previousActiveTexture);
  glPushAttrib(GL_COLOR_BUFFER_BIT | GL_CURRENT_BIT | GL_DEPTH_BUFFER_BIT |
               GL_ENABLE_BIT | GL_TEXTURE_BIT | GL_TRANSFORM_BIT |
               GL_VIEWPORT_BIT);
  glViewport(x, y, width, height);
  glDisable(GL_BLEND);
  glDisable(GL_DEPTH_TEST);
  glDepthMask(GL_FALSE);
  glActiveTexture(GL_TEXTURE0);
  glEnable(GL_TEXTURE_2D);
  glBindTexture(GL_TEXTURE_2D, backgroundTexture);
  glTexEnvi(GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, GL_REPLACE);

  glMatrixMode(GL_PROJECTION);
  glPushMatrix();
  glLoadIdentity();
  glMatrixMode(GL_MODELVIEW);
  glPushMatrix();
  glLoadIdentity();

  // CUDA row zero is the top of the image; OpenGL texture row zero is the
  // bottom.  Reverse T while drawing instead of copying the frame again.
  glBegin(GL_QUADS);
  glTexCoord2f(0.0f, 1.0f);
  glVertex2f(-1.0f, -1.0f);
  glTexCoord2f(0.0f, 0.0f);
  glVertex2f(-1.0f, 1.0f);
  glTexCoord2f(1.0f, 0.0f);
  glVertex2f(1.0f, 1.0f);
  glTexCoord2f(1.0f, 1.0f);
  glVertex2f(1.0f, -1.0f);
  glEnd();

  glPopMatrix();
  glMatrixMode(GL_PROJECTION);
  glPopMatrix();
  glMatrixMode(previousMatrixMode);
  glActiveTexture(previousActiveTexture);
  glPopAttrib();
}
}  // namespace

extern "C" int monadiusRayBackgroundShouldStop() {
  return stopRequested.load(std::memory_order_relaxed) ? 1 : 0;
}

extern "C" void monadiusPublishRayBackgroundRgb(
    const float* red, const float* green, const float* blue, int width,
    int height) {
  if (!backgroundEnabled || red == nullptr || green == nullptr ||
      blue == nullptr || width != backgroundWidth ||
      height != backgroundHeight) {
    return;
  }

  int writableBuffer = 0;
  {
    std::lock_guard<std::mutex> lock(frameMutex);
    writableBuffer = 1 - frontBufferIndex;
  }

  std::vector<unsigned char>& pixels = frameBuffers[writableBuffer];
  const size_t pixelCount =
      static_cast<size_t>(backgroundWidth) * backgroundHeight;
  for (size_t pixel = 0; pixel < pixelCount; ++pixel) {
    const size_t offset = pixel * 4;
    pixels[offset] = byteChannel(red[pixel]);
    pixels[offset + 1] = byteChannel(green[pixel]);
    pixels[offset + 2] = byteChannel(blue[pixel]);
    pixels[offset + 3] = 255;
  }

  // The OpenGL thread holds the same mutex for the complete texture upload.
  // Once this swap completes, Lisp can safely reuse the old front buffer.
  {
    std::lock_guard<std::mutex> lock(frameMutex);
    frontBufferIndex = writableBuffer;
    publishedGeneration.fetch_add(1, std::memory_order_release);
  }
}

extern "C" void monadiusReportRayBackgroundError(const char* message) {
  std::fprintf(stderr, "Live ray background Lisp error: %s\n",
               message != nullptr ? message : "unknown error");
}

extern "C" int initRayBackground() {
  if (!enabledByEnvironment()) return 1;
  if (backgroundInitialized) return 1;

  backgroundWidth =
      positiveEnvironmentInteger("MONADIUS_RAY_WIDTH", 800);
  backgroundHeight =
      positiveEnvironmentInteger("MONADIUS_RAY_HEIGHT", 600);
  const size_t width = static_cast<size_t>(backgroundWidth);
  const size_t height = static_cast<size_t>(backgroundHeight);
  if (height > std::numeric_limits<size_t>::max() / width ||
      width * height > std::numeric_limits<size_t>::max() / 4) {
    std::fputs("Live ray background dimensions overflow host memory.\n",
               stderr);
    return 0;
  }

  const size_t pixelCount = width * height;
  try {
    fillOpaqueBlack(frameBuffers[0], pixelCount);
    fillOpaqueBlack(frameBuffers[1], pixelCount);
  } catch (const std::exception& error) {
    std::fprintf(stderr,
                 "Could not allocate live ray background host buffers: %s\n",
                 error.what());
    frameBuffers[0].clear();
    frameBuffers[1].clear();
    return 0;
  }
  frontBufferIndex = 0;
  publishedGeneration.store(1, std::memory_order_relaxed);
  uploadedGeneration = 1;
  reportedUploadFailureGeneration = 0;
  if (!createBackgroundTexture()) {
    frameBuffers[0].clear();
    frameBuffers[1].clear();
    return 0;
  }

  if (!initializeSbcl()) {
    deleteBackgroundTexture();
    frameBuffers[0].clear();
    frameBuffers[1].clear();
    return 0;
  }

  stopRequested.store(false, std::memory_order_relaxed);
  backgroundEnabled = true;
  backgroundInitialized = true;
  try {
    lispWorker = std::thread([] {
      monadius_lisp_ray_background_run(backgroundWidth, backgroundHeight);
    });
  } catch (const std::exception& error) {
    std::fprintf(stderr,
                 "Could not start the live ray background worker: %s\n",
                 error.what());
    backgroundEnabled = false;
    backgroundInitialized = false;
    deleteBackgroundTexture();
    frameBuffers[0].clear();
    frameBuffers[1].clear();
    return 0;
  }
  std::fprintf(stderr,
               "Live ray background started in-process at %dx%d.\n",
               backgroundWidth, backgroundHeight);
  return 1;
}

extern "C" void renderRayBackground(int x, int y, int width, int height) {
  if (!backgroundEnabled || backgroundTexture == 0 || width <= 0 ||
      height <= 0) {
    return;
  }
  uploadNewestFrameIfNeeded();
  drawBackgroundQuad(x, y, width, height);
}

extern "C" void finishRayBackground() {
  if (!backgroundInitialized) return;
  stopRequested.store(true, std::memory_order_relaxed);
  if (lispWorker.joinable()) lispWorker.join();
  backgroundEnabled = false;
  backgroundInitialized = false;
  deleteBackgroundTexture();
  frameBuffers[0].clear();
  frameBuffers[1].clear();
  // SBCL documents no supported in-process shutdown.  Keep libsbcl loaded;
  // the operating system reclaims it when the Monadius process exits.
}
