#include <Effekseer/Effekseer.h>
#include <EffekseerRendererGL/EffekseerRendererGL.h>

#include <array>
#include <cstdlib>
#include <fstream>
#include <string>

namespace {
constexpr int kEffectTerm = 160;

EffekseerRendererGL::RendererRef renderer;
Effekseer::ManagerRef manager;
Effekseer::EffectRef effect;
Effekseer::Handle handle = 0;
int effectTime = kEffectTerm - 1;

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
  renderer->SetCameraMatrix(Effekseer::Matrix44().LookAtRH(
      Effekseer::Vector3D(values[0], values[1], values[2]),
      Effekseer::Vector3D(values[3], values[4], values[5]),
      Effekseer::Vector3D(values[6], values[7], values[8])));
}

void loadEffect(const char* parameters, const char16_t* effectPath) {
  if (manager.Get() == nullptr || renderer.Get() == nullptr) return;
  manager->StopEffect(handle);
  setCamera(parameters);
  effect = Effekseer::Effect::Create(manager, effectPath);
  effectTime = 0;
}
}  // namespace

void restartEffekseer(int kind) {
  switch (kind) {
    case 1:  loadEffect("Params/marisa.txt", u"Effects/marisa.efk"); break;
    case 2:  loadEffect("Params/tsuki.txt", u"Effects/tsuki.efk"); break;
    case 3:  loadEffect("Params/craw.txt", u"Effects/craw.efk"); break;
    case 4:  loadEffect("Params/warero.txt", u"Effects/warero.efk"); break;
    case 5:  loadEffect("Params/icchimae.txt", u"Effects/icchimae.efk"); break;
    case 6:  loadEffect("Params/kaze.txt", u"Effects/kaze.efk"); break;
    case 12: loadEffect("Params/open.txt", u"Effects/open.efk"); break;
    default: break;
  }
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
  if (effect.Get() != nullptr && effectTime == 0) handle = manager->Play(effect, 0, 0, 0);
  if (effect.Get() != nullptr && effectTime == kEffectTerm - 1) manager->StopEffect(handle);
  if (effect.Get() != nullptr) effectTime = (effectTime + 1) % kEffectTerm;
  manager->Update();
  renderer->BeginRendering();
  manager->Draw();
  renderer->EndRendering();
}

void finishEffekseer() {
  manager.Reset();
  renderer.Reset();
}
