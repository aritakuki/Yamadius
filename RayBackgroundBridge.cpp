#define GL_GLEXT_PROTOTYPES
#include <GL/gl.h>
#include <GL/glext.h>

#include <algorithm>
#include <cerrno>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <spawn.h>
#include <string>
#include <vector>

#include <signal.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

extern char** environ;

namespace {
constexpr uint64_t kSharedMagic = UINT64_C(0x4d4f4e4152495553);
constexpr uint32_t kSharedVersion = 1;
constexpr uint32_t kBufferCount = 3;
constexpr uint32_t kPixelFormatRgba8 = 1;
constexpr uint32_t kNoReader = UINT32_MAX;

enum ProducerState : uint32_t {
  kProducerCreated = 0,
  kProducerRunning = 1,
  kProducerFailed = 2,
  kProducerStopped = 3,
};

// The producer library in lisp-raytracer has the same explicit layout.  The
// frequently-read coordination words have their own cache line and are plain
// integers so both C and C++ can use GCC's process-shared __atomic builtins.
struct alignas(64) SharedHeader {
  uint64_t magic;                 // 0
  uint32_t version;               // 8
  uint32_t headerBytes;           // 12
  uint32_t width;                 // 16
  uint32_t height;                // 20
  uint32_t bufferCount;           // 24
  uint32_t pixelFormat;           // 28
  uint64_t pixelBytes;            // 32
  uint64_t totalBytes;            // 40
  uint32_t producerPid;           // 48
  uint32_t reserved0;             // 52
  uint64_t reserved1;             // 56
  uint64_t generation;            // 64
  uint32_t frontIndex;            // 72
  uint32_t readerIndex;           // 76
  uint32_t stopRequested;         // 80
  uint32_t producerState;         // 84
  int32_t producerError;          // 88
  uint32_t reserved2;             // 92
  uint64_t heartbeat;             // 96
  unsigned char reserved3[24];    // 104
};

static_assert(sizeof(SharedHeader) == 128,
              "live background shared header must be 128 bytes");
static_assert(offsetof(SharedHeader, generation) == 64,
              "live background atomic fields moved");
static_assert(offsetof(SharedHeader, heartbeat) == 96,
              "live background protocol layout changed");

SharedHeader* sharedHeader = nullptr;
unsigned char* sharedPixels = nullptr;
size_t sharedMappingBytes = 0;
pid_t producerPid = -1;
bool producerReaped = false;
bool producerExitReported = false;
bool producerFailureReported = false;

int backgroundWidth = 0;
int backgroundHeight = 0;
GLuint backgroundTexture = 0;
bool backgroundEnabled = false;
bool backgroundInitialized = false;
uint64_t uploadedGeneration = 0;
uint64_t reportedUploadFailureGeneration = 0;

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

std::string environmentOrDefault(const char* name, const char* fallback) {
  const char* value = std::getenv(name);
  return value != nullptr && *value != '\0' ? value : fallback;
}

std::string quicklispSetupPath() {
  const char* configured = std::getenv("QUICKLISP_SETUP");
  if (configured != nullptr && *configured != '\0') return configured;
  const char* home = std::getenv("HOME");
  return std::string(home != nullptr && *home != '\0' ? home : "/root") +
         "/quicklisp/setup.lisp";
}

template <typename T>
T atomicLoad(const T* value) {
  return __atomic_load_n(value, __ATOMIC_SEQ_CST);
}

template <typename T>
void atomicStore(T* target, T value) {
  __atomic_store_n(target, value, __ATOMIC_SEQ_CST);
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
               backgroundHeight, 0, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);

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

int createAnonymousMemory(const char* name) {
#if defined(SYS_memfd_create)
  return static_cast<int>(syscall(SYS_memfd_create, name, 0));
#else
  (void)name;
  errno = ENOSYS;
  return -1;
#endif
}

void releaseSharedMemory() {
  if (sharedHeader != nullptr) {
    munmap(sharedHeader, sharedMappingBytes);
  }
  sharedHeader = nullptr;
  sharedPixels = nullptr;
  sharedMappingBytes = 0;
}

bool allocateSharedMemory(int* inheritedFd) {
  const size_t width = static_cast<size_t>(backgroundWidth);
  const size_t height = static_cast<size_t>(backgroundHeight);
  if (height > std::numeric_limits<size_t>::max() / width ||
      width * height > std::numeric_limits<size_t>::max() / 4) {
    std::fputs("Live ray background dimensions overflow host memory.\n", stderr);
    return false;
  }
  const size_t pixelBytes = width * height * 4;
  if (pixelBytes >
      (std::numeric_limits<size_t>::max() - sizeof(SharedHeader)) /
          kBufferCount) {
    std::fputs("Live ray background buffers overflow host memory.\n", stderr);
    return false;
  }
  sharedMappingBytes = sizeof(SharedHeader) + pixelBytes * kBufferCount;

  const int fd = createAnonymousMemory("monadius-ray-background");
  if (fd < 0) {
    std::fprintf(stderr,
                 "Could not create anonymous live background memory: %s.\n",
                 std::strerror(errno));
    sharedMappingBytes = 0;
    return false;
  }
  if (ftruncate(fd, static_cast<off_t>(sharedMappingBytes)) != 0) {
    std::fprintf(stderr,
                 "Could not size anonymous live background memory: %s.\n",
                 std::strerror(errno));
    close(fd);
    sharedMappingBytes = 0;
    return false;
  }
  void* mapping = mmap(nullptr, sharedMappingBytes, PROT_READ | PROT_WRITE,
                       MAP_SHARED, fd, 0);
  if (mapping == MAP_FAILED) {
    std::fprintf(stderr, "Could not map live background memory: %s.\n",
                 std::strerror(errno));
    close(fd);
    sharedMappingBytes = 0;
    return false;
  }

  sharedHeader = static_cast<SharedHeader*>(mapping);
  sharedPixels = reinterpret_cast<unsigned char*>(sharedHeader + 1);
  std::memset(mapping, 0, sharedMappingBytes);
  sharedHeader->magic = kSharedMagic;
  sharedHeader->version = kSharedVersion;
  sharedHeader->headerBytes = sizeof(SharedHeader);
  sharedHeader->width = static_cast<uint32_t>(backgroundWidth);
  sharedHeader->height = static_cast<uint32_t>(backgroundHeight);
  sharedHeader->bufferCount = kBufferCount;
  sharedHeader->pixelFormat = kPixelFormatRgba8;
  sharedHeader->pixelBytes = pixelBytes;
  sharedHeader->totalBytes = sharedMappingBytes;
  atomicStore(&sharedHeader->frontIndex, uint32_t{0});
  atomicStore(&sharedHeader->readerIndex, kNoReader);
  atomicStore(&sharedHeader->stopRequested, uint32_t{0});
  atomicStore(&sharedHeader->producerState,
              static_cast<uint32_t>(kProducerCreated));
  atomicStore(&sharedHeader->generation, uint64_t{0});
  *inheritedFd = fd;
  return true;
}

bool environmentEntryHasName(const char* entry, const std::string& name) {
  return std::strncmp(entry, name.c_str(), name.size()) == 0 &&
         entry[name.size()] == '=';
}

void appendChildEnvironment(std::vector<std::string>* storage,
                            const std::string& name,
                            const std::string& value) {
  storage->push_back(name + "=" + value);
}

bool spawnLispProducer(int inheritedFd) {
  const std::string sbcl =
      environmentOrDefault("MONADIUS_SBCL", "/usr/bin/sbcl");
  const std::string entry = environmentOrDefault(
      "MONADIUS_RAY_LISP_ENTRY",
      "/content/lisp-raytracer/GPU/run-shared-background.lsp");
  const std::string bridge = environmentOrDefault(
      "MONADIUS_RAY_SHARED_LIBRARY",
      "/content/monadius-ray-runtime/lib/libmonadius_ray_shared.so");
  const std::string quicklisp = quicklispSetupPath();

  if (access(entry.c_str(), R_OK) != 0) {
    std::fprintf(stderr, "Live ray background Lisp entry not found: %s\n",
                 entry.c_str());
    return false;
  }
  if (access(bridge.c_str(), R_OK) != 0) {
    std::fprintf(stderr, "Live ray background shared library not found: %s\n",
                 bridge.c_str());
    return false;
  }
  if (access(quicklisp.c_str(), R_OK) != 0) {
    std::fprintf(stderr, "Quicklisp setup not found: %s\n",
                 quicklisp.c_str());
    return false;
  }
  if (sbcl.find('/') != std::string::npos && access(sbcl.c_str(), X_OK) != 0) {
    std::fprintf(stderr, "SBCL executable not found: %s\n", sbcl.c_str());
    return false;
  }

  const std::vector<std::string> overridden = {
      "MONADIUS_RAY_SHARED_FD", "MONADIUS_RAY_PARENT_PID",
      "MONADIUS_RAY_SHARED_LIBRARY", "MONADIUS_RAY_WIDTH",
      "MONADIUS_RAY_HEIGHT", "QUICKLISP_SETUP"};
  std::vector<std::string> childEnvironmentStorage;
  for (char** item = environ; item != nullptr && *item != nullptr; ++item) {
    bool skip = false;
    for (const std::string& name : overridden) {
      if (environmentEntryHasName(*item, name)) {
        skip = true;
        break;
      }
    }
    if (!skip) childEnvironmentStorage.emplace_back(*item);
  }
  appendChildEnvironment(&childEnvironmentStorage, "MONADIUS_RAY_SHARED_FD",
                         std::to_string(inheritedFd));
  appendChildEnvironment(&childEnvironmentStorage, "MONADIUS_RAY_PARENT_PID",
                         std::to_string(static_cast<long long>(getpid())));
  appendChildEnvironment(&childEnvironmentStorage,
                         "MONADIUS_RAY_SHARED_LIBRARY", bridge);
  appendChildEnvironment(&childEnvironmentStorage, "MONADIUS_RAY_WIDTH",
                         std::to_string(backgroundWidth));
  appendChildEnvironment(&childEnvironmentStorage, "MONADIUS_RAY_HEIGHT",
                         std::to_string(backgroundHeight));
  appendChildEnvironment(&childEnvironmentStorage, "QUICKLISP_SETUP", quicklisp);

  std::vector<char*> childEnvironment;
  childEnvironment.reserve(childEnvironmentStorage.size() + 1);
  for (std::string& item : childEnvironmentStorage) {
    childEnvironment.push_back(const_cast<char*>(item.c_str()));
  }
  childEnvironment.push_back(nullptr);

  std::vector<std::string> argumentStorage = {
      sbcl,          "--noinform",   "--non-interactive",
      "--no-userinit", "--no-sysinit", "--disable-debugger",
      "--load",     entry};
  std::vector<char*> arguments;
  arguments.reserve(argumentStorage.size() + 1);
  for (std::string& argument : argumentStorage) {
    arguments.push_back(const_cast<char*>(argument.c_str()));
  }
  arguments.push_back(nullptr);

  pid_t child = -1;
  const int result = posix_spawnp(&child, sbcl.c_str(), nullptr, nullptr,
                                  arguments.data(), childEnvironment.data());
  if (result != 0) {
    std::fprintf(stderr, "Could not start the SBCL background process: %s.\n",
                 std::strerror(result));
    return false;
  }
  producerPid = child;
  producerReaped = false;
  producerExitReported = false;
  sharedHeader->producerPid = static_cast<uint32_t>(child);
  return true;
}

void reportProducerExit(int status) {
  if (producerExitReported) return;
  producerExitReported = true;
  if (WIFEXITED(status)) {
    const int code = WEXITSTATUS(status);
    std::fprintf(stderr,
                 "Live ray background SBCL process exited with status %d%s.\n",
                 code, code == 0 ? "" : " (see preceding Lisp error)");
  } else if (WIFSIGNALED(status)) {
    std::fprintf(stderr,
                 "Live ray background SBCL process ended from signal %d.\n",
                 WTERMSIG(status));
  } else {
    std::fputs("Live ray background SBCL process ended unexpectedly.\n", stderr);
  }
}

void monitorProducer() {
  if (producerPid <= 0 || producerReaped) return;
  int status = 0;
  const pid_t result = waitpid(producerPid, &status, WNOHANG);
  if (result == producerPid) {
    producerReaped = true;
    reportProducerExit(status);
  } else if (result < 0 && errno != EINTR) {
    std::fprintf(stderr, "Could not query the Lisp background process: %s.\n",
                 std::strerror(errno));
    producerReaped = true;
  }

  if (sharedHeader != nullptr && !producerFailureReported &&
      atomicLoad(&sharedHeader->producerState) == kProducerFailed) {
    producerFailureReported = true;
    std::fprintf(stderr,
                 "Live ray background producer reported error code %d.\n",
                 atomicLoad(&sharedHeader->producerError));
  }
}

bool claimNewestFrame(uint64_t* generation, uint32_t* index) {
  for (int attempt = 0; attempt < 3; ++attempt) {
    const uint64_t observedGeneration =
        atomicLoad(&sharedHeader->generation);
    if (observedGeneration == 0 || observedGeneration == uploadedGeneration) {
      return false;
    }
    const uint32_t observedIndex = atomicLoad(&sharedHeader->frontIndex);
    if (observedIndex >= kBufferCount) return false;

    atomicStore(&sharedHeader->readerIndex, observedIndex);
    if (observedGeneration == atomicLoad(&sharedHeader->generation) &&
        observedIndex == atomicLoad(&sharedHeader->frontIndex)) {
      *generation = observedGeneration;
      *index = observedIndex;
      return true;
    }
    atomicStore(&sharedHeader->readerIndex, kNoReader);
  }
  return false;
}

void releaseClaimedFrame() {
  atomicStore(&sharedHeader->readerIndex, kNoReader);
}

void uploadNewestFrameIfNeeded() {
  monitorProducer();
  uint64_t generation = 0;
  uint32_t index = 0;
  if (!claimNewestFrame(&generation, &index)) return;

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
  const unsigned char* pixels =
      sharedPixels + static_cast<size_t>(index) * sharedHeader->pixelBytes;
  glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, backgroundWidth,
                  backgroundHeight, GL_RGBA, GL_UNSIGNED_BYTE, pixels);
  const GLenum error = glGetError();
  glPixelStorei(GL_UNPACK_ALIGNMENT, previousUnpackAlignment);
  glBindBuffer(GL_PIXEL_UNPACK_BUFFER,
               static_cast<GLuint>(previousUnpackBuffer));
  glBindTexture(GL_TEXTURE_2D, static_cast<GLuint>(previousTexture));
  glActiveTexture(previousActiveTexture);
  releaseClaimedFrame();

  if (error == GL_NO_ERROR) {
    if (uploadedGeneration == 0) {
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
  // bottom. Reverse T while drawing instead of copying the frame again.
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

bool waitForProducerMilliseconds(int milliseconds) {
  const int polls = std::max(1, milliseconds / 10);
  for (int poll = 0; poll < polls; ++poll) {
    if (producerReaped || producerPid <= 0) return true;
    int status = 0;
    const pid_t result = waitpid(producerPid, &status, WNOHANG);
    if (result == producerPid) {
      producerReaped = true;
      reportProducerExit(status);
      return true;
    }
    if (result < 0 && errno != EINTR) {
      producerReaped = true;
      return true;
    }
    usleep(10000);
  }
  return producerReaped;
}

void stopProducer() {
  if (sharedHeader != nullptr) {
    atomicStore(&sharedHeader->stopRequested, uint32_t{1});
  }
  if (producerPid <= 0 || producerReaped) return;
  if (waitForProducerMilliseconds(2000)) return;

  std::fprintf(stderr,
               "Live ray background did not stop between frames; sending SIGTERM.\n");
  kill(producerPid, SIGTERM);
  if (waitForProducerMilliseconds(1000)) return;

  std::fprintf(stderr,
               "Live ray background ignored SIGTERM; sending SIGKILL.\n");
  kill(producerPid, SIGKILL);
  int status = 0;
  while (waitpid(producerPid, &status, 0) < 0 && errno == EINTR) {
  }
  producerReaped = true;
  reportProducerExit(status);
}
}  // namespace

extern "C" int initRayBackground() {
  if (!enabledByEnvironment()) return 1;
  if (backgroundInitialized) return 1;

  backgroundWidth = positiveEnvironmentInteger("MONADIUS_RAY_WIDTH", 800);
  backgroundHeight = positiveEnvironmentInteger("MONADIUS_RAY_HEIGHT", 600);
  int inheritedFd = -1;
  if (!allocateSharedMemory(&inheritedFd)) return 0;
  if (!createBackgroundTexture()) {
    close(inheritedFd);
    releaseSharedMemory();
    return 0;
  }
  if (!spawnLispProducer(inheritedFd)) {
    close(inheritedFd);
    deleteBackgroundTexture();
    releaseSharedMemory();
    return 0;
  }
  // Both existing mappings remain valid after close. The child inherited this
  // descriptor through posix_spawn and closes it after its own mmap succeeds.
  close(inheritedFd);

  backgroundEnabled = true;
  backgroundInitialized = true;
  uploadedGeneration = 0;
  reportedUploadFailureGeneration = 0;
  producerFailureReported = false;
  std::fprintf(stderr,
               "Live ray background started as SBCL process %ld with "
               "anonymous shared memory at %dx%d.\n",
               static_cast<long>(producerPid), backgroundWidth,
               backgroundHeight);
  return 1;
}

extern "C" void renderRayBackground(int x, int y, int width, int height) {
  if (!backgroundEnabled || backgroundTexture == 0 || width <= 0 ||
      height <= 0) {
    return;
  }
  uploadNewestFrameIfNeeded();
  // Before Lisp completes its first generation, retain Monadius' original
  // stage background instead of drawing an uninitialised/black texture.
  if (uploadedGeneration != 0) drawBackgroundQuad(x, y, width, height);
}

extern "C" void finishRayBackground() {
  if (!backgroundInitialized) return;
  stopProducer();
  backgroundEnabled = false;
  backgroundInitialized = false;
  deleteBackgroundTexture();
  releaseSharedMemory();
  producerPid = -1;
  producerReaped = false;
}
