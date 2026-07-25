#include <Effekseer/Effekseer.h>
#include <EffekseerRendererGL/EffekseerRendererGL.h>

#include <array>
#include <cmath>
#include <cstdlib>
#include <fstream>
#include <string>

namespace {
constexpr int kEffectTerm = 160;
constexpr int kWindEffectTerm = 240;

EffekseerRendererGL::RendererRef renderer;
Effekseer::ManagerRef manager;
Effekseer::EffectRef effect;
Effekseer::Handle handle = 0;
int effectTime = kEffectTerm - 1;
int effectTerm = kEffectTerm;
bool effectFollowsPlayer = false;
float playerScreenX = 0.0f;
float playerScreenY = 0.0f;
std::array<float, 3> cameraRight = {1.0f, 0.0f, 0.0f};
std::array<float, 3> cameraUp = {0.0f, 1.0f, 0.0f};
std::array<float, 3> cameraTarget = {0.0f, 0.0f, 0.0f};

std::array<float, 3> normalize(const std::array<float, 3>& vector) {
  const float length = std::sqrt(vector[0] * vector[0] + vector[1] * vector[1] +
                                 vector[2] * vector[2]);
  return length == 0.0f ? std::array<float, 3>{0.0f, 0.0f, 0.0f}
                        : std::array<float, 3>{vector[0] / length, vector[1] / length,
                                               vector[2] / length};
}

std::array<float, 3> cross(const std::array<float, 3>& left,
                            const std::array<float, 3>& right) {
  return {left[1] * right[2] - left[2] * right[1],
          left[2] * right[0] - left[0] * right[2],
          left[0] * right[1] - left[1] * right[0]};
}

std::array<float, 9> readCameraParameters(const char* path) {
  std::array<float, 9> values = {10.0f, 5.0f, 20.0f, 4.0f, 0.0f,
                                  0.0f, 0.0f, 10.0f, 0.0f};
  std::ifstream input(path);
  std::string line;
  for (auto& value : values) {
    if (!std::getline(input, line)) break;
    value = std::strtof(line.c_str(), nullptr);
  }
  return values;
}

void setCamera(const char* path) {
  const auto values = readCameraParameters(path);
  cameraTarget = {values[3], values[4], values[5]};
  const std::array<float, 3> forward = normalize(
      {values[3] - values[0], values[4] - values[1], values[5] - values[2]});
  cameraRight = normalize(cross(forward, {values[6], values[7], values[8]}));
  cameraUp = normalize(cross(cameraRight, forward));
  renderer->SetCameraMatrix(Effekseer::Matrix44().LookAtRH(
      Effekseer::Vector3D(values[0], values[1], values[2]),
      Effekseer::Vector3D(values[3], values[4], values[5]),
      Effekseer::Vector3D(values[6], values[7], values[8])));
}

void loadEffect(const char* parameters, const char16_t* effectPath,
                int term = kEffectTerm, bool followsPlayer = false) {
  if (manager.Get() == nullptr || renderer.Get() == nullptr) return;
  manager->StopEffect(handle);
  setCamera(parameters);
  effect = Effekseer::Effect::Create(manager, effectPath);
  effectTime = 0;
  effectTerm = term;
  effectFollowsPlayer = followsPlayer;
}
}  // namespace

void restartEffekseer(int kind) {
  switch (kind) {
    case 1:  loadEffect("Params/marisa.txt", u"Effects/marisa.efk", kEffectTerm, true); break;
    case 2:  loadEffect("Params/tsuki.txt", u"Effects/tsuki.efk"); break;
    case 3:  loadEffect("Params/craw.txt", u"Effects/craw.efk"); break;
    case 4:  loadEffect("Params/warero.txt", u"Effects/warero.efk"); break;
    case 5:  loadEffect("Params/icchimae.txt", u"Effects/icchimae.efk"); break;
    case 6:  loadEffect("Params/kaze.txt", u"Effects/kaze.efk", kWindEffectTerm); break;
    case 12: loadEffect("Params/open.txt", u"Effects/open.efk"); break;
    default: break;
  }
}

extern "C" void setEffekseerPlayerPosition(float x, float y) {
  playerScreenX = x;
  playerScreenY = y;
}

void initEffekseer(int32_t windowWidth, int32_t windowHeight) {
  renderer = EffekseerRendererGL::Renderer::Create(
      8000, EffekseerRendererGL::OpenGLDeviceType::OpenGL3);
  manager = Effekseer::Manager::Create(8000);
  manager->SetSpriteRenderer(renderer->CreateSpriteRenderer());
  manager->SetRibbonRenderer(renderer->CreateRibbonRenderer());
  manager->SetRingRenderer(renderer->CreateRingRenderer());
  manager->SetTrackRenderer(renderer->CreateTrackRenderer());
  manager->SetModelRenderer(renderer->CreateModelRenderer());
  manager->SetTextureLoader(renderer->CreateTextureLoader());
  manager->SetModelLoader(renderer->CreateModelLoader());
  manager->SetMaterialLoader(renderer->CreateMaterialLoader());
  manager->SetCurveLoader(Effekseer::MakeRefPtr<Effekseer::CurveLoader>());
  renderer->SetProjectionMatrix(Effekseer::Matrix44().PerspectiveFovRH_OpenGL(
      30.0f / 180.0f * 3.14f,
      static_cast<float>(windowWidth) / static_cast<float>(windowHeight),
      0.0f, 500.0f));
  setCamera("Params/marisa.txt");
}

void procEffekseer() {
  if (manager.Get() == nullptr || renderer.Get() == nullptr) return;
  if (effect.Get() != nullptr && effectTime == 0) {
    // Monadius uses roughly 640x480 world coordinates, while the Effekseer
    // camera shows a world about sixteen units across.  Project the player's
    // 2D position onto the active effect camera plane.
    constexpr float kScreenToEffectScale = 1.0f / 40.0f;
    const float effectX = cameraTarget[0] + kScreenToEffectScale *
        (cameraRight[0] * playerScreenX + cameraUp[0] * playerScreenY);
    const float effectY = cameraTarget[1] + kScreenToEffectScale *
        (cameraRight[1] * playerScreenX + cameraUp[1] * playerScreenY);
    const float effectZ = cameraTarget[2] + kScreenToEffectScale *
        (cameraRight[2] * playerScreenX + cameraUp[2] * playerScreenY);
    handle = manager->Play(effect, effectFollowsPlayer ? effectX : 0.0f,
                           effectFollowsPlayer ? effectY : 0.0f,
                           effectFollowsPlayer ? effectZ : 0.0f);
  }
  if (effect.Get() != nullptr && effectTime == effectTerm - 1) {
    manager->StopEffect(handle);
    effect.Reset();
    handle = 0;
  } else if (effect.Get() != nullptr) {
    ++effectTime;
  }
  manager->Update();
  renderer->BeginRendering();
  manager->Draw();
  renderer->EndRendering();
}

void finishEffekseer() {
  manager.Reset();
  renderer.Reset();
}
