#pragma once
#include <array>
#include <functional>
#include <string>
#include <utility>
#include <vector>
namespace xs {
constexpr std::size_t orInputLimit = 128 * 1024;
constexpr std::size_t orResponseLimit = 2 * 1024 * 1024;
enum class AiProvider { openRouter, google, nvidia, deepseek, openai, claude, ollama, azure, groq, grok, count };
enum class AiOperation { generate, listModels, checkKey };
enum class AiOutputMode { replace, insertBelow, newWindow, displayOnly };
struct AiTemplate {
  std::string name, instruction;
  AiOutputMode output = AiOutputMode::replace;
  bool operator==(const AiTemplate &other) const {
    return name == other.name && instruction == other.instruction &&
           output == other.output;
  }
};
const char *aiOutputName(AiOutputMode mode);
std::vector<AiTemplate> aiDefaultTemplates();
void aiValidateTemplates(const std::vector<AiTemplate> &templates);
void aiMergeTemplates(std::vector<AiTemplate> &latest,
                      const std::vector<AiTemplate> &before,
                      const std::vector<AiTemplate> &draft);
struct AiModel {
  std::string id, label;
  bool operator==(const AiModel &other) const {
    return id == other.id && label == other.label;
  }
};
class AiStream {
public:
  explicit AiStream(AiProvider provider);
  bool feed(const char *bytes, std::size_t size);
  const std::string &text() const { return answer; }
  std::string finish() const;
private:
  void record(const std::string &data);
  void append(const std::string &text);
  AiProvider provider;
  std::string pending, event, answer;
  bool complete = false, stopped = false;
};
struct AiModelPage {
  std::vector<AiModel> models;
  std::string next;
};
struct AiEndpoint {
  std::string host, method, path;
  unsigned short port = 443;
  bool secure = true;
};
struct AiServiceSettings {
  std::string key, model;
  std::vector<AiModel> models;
  std::string endpoint{};
  bool operator==(const AiServiceSettings &other) const {
    return key == other.key && model == other.model && models == other.models &&
           endpoint == other.endpoint;
  }
  bool operator!=(const AiServiceSettings &other) const { return !(*this == other); }
};
struct OrPreferences {
  std::string key, googleKey, googleModel;
  AiProvider provider = AiProvider::openRouter;
  std::vector<AiModel> googleModels;
  AiServiceSettings nvidia, deepseek;
  std::array<AiServiceSettings, 6> additional;
  const std::string &activeEndpoint() const;
  std::string &activeEndpoint();
  const std::string &activeKey() const;
  std::string &activeKey();
  const std::string &activeModel() const;
  std::string &activeModel();
  const std::vector<AiModel> &activeModels() const;
  std::vector<AiModel> &activeModels();
  std::vector<std::string> prompts;
  std::vector<AiTemplate> templates = aiDefaultTemplates();
  ~OrPreferences() {
    const auto wipe = [](std::string &secret) {
      if (!secret.empty()) {
        volatile char *p = &secret[0];
        for (std::size_t i = 0; i < secret.size(); ++i)
          p[i] = 0;
      }
    };
    for (auto *secret : {&key, &googleKey, &nvidia.key, &deepseek.key})
      wipe(*secret);
    for (auto &service : additional)
      wipe(service.key);
  }
};
bool aiIsNewProvider(AiProvider provider);
bool aiUsesEndpoint(AiProvider provider);
bool aiValidEndpoint(AiProvider provider, const std::string &endpoint);
bool aiRequiresKey(AiProvider provider);
bool aiListsModels(AiProvider provider);
bool aiConnectionReady(const OrPreferences &prefs);
const char *aiProviderName(AiProvider provider);
const char *aiKeyPage(AiProvider provider);
std::string aiSelectedModel(const OrPreferences &prefs);
bool validGoogleModel(const std::string &model);
bool validAiModel(AiProvider provider, const std::string &model);
AiEndpoint aiEndpoint(AiProvider provider, AiOperation operation,
                      const std::string &model = {},
                      const std::string &page = {},
                      const std::string &endpoint = {});
std::string aiRequest(AiProvider provider, const std::string &instruction,
                      const std::string &text, const std::string &model = {},
                      bool stream = false);
// Extract the actual system/user text from the already serialized request.
// UI headings are separate and never inserted into the API payload.
std::pair<std::string, std::string> aiPromptContents(
    AiProvider provider, const std::string &request);
std::string aiAnswer(AiProvider provider, unsigned status,
                     const std::string &body);
AiModelPage googleModelPage(unsigned status, const std::string &body);
std::vector<AiModel> googleModels(
    const std::function<std::pair<unsigned, std::string>(const std::string &)>
        &fetch);
std::vector<AiModel> aiModels(AiProvider provider,
    const std::function<std::pair<unsigned, std::string>(const std::string &)> &fetch);
void aiCopySettings(OrPreferences &target, const OrPreferences &source);
void aiMergeSettings(OrPreferences &latest, const OrPreferences &before,
                     const OrPreferences &draft);
bool aiSameConnection(const OrPreferences &a, const OrPreferences &b);
bool validOrKey(const std::string &key);
std::string orRequest(const std::string &prompt, const std::string &text);
std::string orAnswer(unsigned status, const std::string &body);
void orCheckKey(unsigned status, const std::string &body);
std::string orDefaultPrompt(const OrPreferences &prefs);
void orRemember(OrPreferences &prefs, const std::string &prompt);
std::string orSavePreferences(const OrPreferences &prefs);
OrPreferences orLoadPreferences(const std::string &json);
std::string orNormalizeEol(const std::string &text, int eolMode);
// A changed document (even an edit subsequently undone) must not be
// overwritten.
bool orCanApply(bool sameDocument, bool sameBytes, bool sameEncoding,
                bool writable, unsigned long long initialRevision,
                unsigned long long currentRevision);
} // namespace xs
