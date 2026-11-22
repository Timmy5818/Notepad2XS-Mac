#pragma once
#include <functional>
#include <string>
#include <utility>
#include <vector>
namespace xs {
constexpr std::size_t orInputLimit = 128 * 1024;
constexpr std::size_t orResponseLimit = 2 * 1024 * 1024;
enum class AiProvider { openRouter, google, nvidia, deepseek };
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
struct AiModelPage {
  std::vector<AiModel> models;
  std::string next;
};
struct AiEndpoint {
  std::string host, method, path;
};
struct AiServiceSettings {
  std::string key, model;
  std::vector<AiModel> models;
  bool operator==(const AiServiceSettings &other) const {
    return key == other.key && model == other.model && models == other.models;
  }
  bool operator!=(const AiServiceSettings &other) const { return !(*this == other); }
};
struct OrPreferences {
  std::string key, googleKey, googleModel;
  AiProvider provider = AiProvider::openRouter;
  std::vector<AiModel> googleModels;
  AiServiceSettings nvidia, deepseek;
  const std::string &activeKey() const;
  std::string &activeKey();
  const std::string &activeModel() const;
  std::string &activeModel();
  const std::vector<AiModel> &activeModels() const;
  std::vector<AiModel> &activeModels();
  std::vector<std::string> prompts;
  std::vector<AiTemplate> templates = aiDefaultTemplates();
  ~OrPreferences() {
    for (auto *secret : {&key, &googleKey, &nvidia.key, &deepseek.key}) {
      if (!secret->empty()) {
        volatile char *p = &(*secret)[0];
        for (std::size_t i = 0; i < secret->size(); ++i)
          p[i] = 0;
      }
    }
  }
};
const char *aiProviderName(AiProvider provider);
const char *aiKeyPage(AiProvider provider);
std::string aiSelectedModel(const OrPreferences &prefs);
bool validGoogleModel(const std::string &model);
bool validAiModel(AiProvider provider, const std::string &model);
AiEndpoint aiEndpoint(AiProvider provider, AiOperation operation,
                      const std::string &model = {},
                      const std::string &page = {});
std::string aiRequest(AiProvider provider, const std::string &instruction,
                      const std::string &text, const std::string &model = {});
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
