#include <jni.h>
#include <string>
#include <vector>

#if defined(ARMIN_LLAMA_GENERATE_READY)
#include "llama.h"
#endif

namespace {

#if defined(ARMIN_LLAMA_GENERATE_READY)
class LlamaBackendScope {
 public:
  LlamaBackendScope() { llama_backend_init(); }
  ~LlamaBackendScope() { llama_backend_free(); }
};

std::string jstring_to_string(JNIEnv *env, jstring value) {
  if (value == nullptr) {
    return "";
  }
  const char *chars = env->GetStringUTFChars(value, nullptr);
  std::string result = chars == nullptr ? "" : chars;
  if (chars != nullptr) {
    env->ReleaseStringUTFChars(value, chars);
  }
  return result;
}

std::vector<llama_token> tokenize(
    const llama_vocab *vocab,
    const std::string &prompt) {
  const int32_t estimated =
      -llama_tokenize(
          vocab,
          prompt.c_str(),
          static_cast<int32_t>(prompt.size()),
          nullptr,
          0,
          true,
          true);
  std::vector<llama_token> tokens(estimated);
  const int32_t count =
      llama_tokenize(
          vocab,
          prompt.c_str(),
          static_cast<int32_t>(prompt.size()),
          tokens.data(),
          static_cast<int32_t>(tokens.size()),
          true,
          true);
  if (count < 0) {
    return {};
  }
  tokens.resize(count);
  return tokens;
}

std::string token_to_piece(const llama_vocab *vocab, llama_token token) {
  std::vector<char> buffer(128);
  int32_t count =
      llama_token_to_piece(
          vocab,
          token,
          buffer.data(),
          static_cast<int32_t>(buffer.size()),
          0,
          false);
  if (count < 0) {
    buffer.resize(static_cast<size_t>(-count));
    count =
        llama_token_to_piece(
            vocab,
            token,
            buffer.data(),
            static_cast<int32_t>(buffer.size()),
            0,
            false);
  }
  if (count <= 0) {
    return "";
  }
  return std::string(buffer.data(), static_cast<size_t>(count));
}

void fill_batch(
    llama_batch &batch,
    const std::vector<llama_token> &tokens,
    int32_t start_position,
    bool logits_last) {
  batch.n_tokens = static_cast<int32_t>(tokens.size());
  for (int32_t i = 0; i < batch.n_tokens; ++i) {
    batch.token[i] = tokens[static_cast<size_t>(i)];
    batch.pos[i] = start_position + i;
    batch.n_seq_id[i] = 1;
    batch.seq_id[i][0] = 0;
    batch.logits[i] = logits_last && i == batch.n_tokens - 1 ? 1 : 0;
  }
}

std::string generate_text(
    const std::string &model_path,
    const std::string &prompt,
    int max_tokens,
    float temperature) {
  static LlamaBackendScope backend;

  llama_model_params model_params = llama_model_default_params();
  model_params.n_gpu_layers = 0;
  llama_model *model =
      llama_model_load_from_file(model_path.c_str(), model_params);
  if (model == nullptr) {
    return "Failed to load GGUF model.";
  }

  const llama_vocab *vocab = llama_model_get_vocab(model);
  std::vector<llama_token> prompt_tokens = tokenize(vocab, prompt);
  if (prompt_tokens.empty()) {
    llama_model_free(model);
    return "Failed to tokenize prompt.";
  }

  llama_context_params ctx_params = llama_context_default_params();
  ctx_params.n_ctx =
      static_cast<uint32_t>(std::max<int>(2048, prompt_tokens.size() + max_tokens + 32));
  ctx_params.n_batch = 512;
  ctx_params.n_threads = 4;
  ctx_params.n_threads_batch = 4;

  llama_context *ctx = llama_init_from_model(model, ctx_params);
  if (ctx == nullptr) {
    llama_model_free(model);
    return "Failed to create llama context.";
  }

  llama_sampler *sampler = llama_sampler_chain_init(
      llama_sampler_chain_default_params());
  if (temperature <= 0.0f) {
    llama_sampler_chain_add(sampler, llama_sampler_init_greedy());
  } else {
    llama_sampler_chain_add(sampler, llama_sampler_init_top_k(40));
    llama_sampler_chain_add(sampler, llama_sampler_init_top_p(0.9f, 1));
    llama_sampler_chain_add(sampler, llama_sampler_init_temp(temperature));
    llama_sampler_chain_add(sampler, llama_sampler_init_dist(LLAMA_DEFAULT_SEED));
  }

  llama_batch batch = llama_batch_init(
      static_cast<int32_t>(std::max<size_t>(prompt_tokens.size(), 1)),
      0,
      1);
  fill_batch(batch, prompt_tokens, 0, true);
  if (llama_decode(ctx, batch) != 0) {
    llama_batch_free(batch);
    llama_sampler_free(sampler);
    llama_free(ctx);
    llama_model_free(model);
    return "Failed to decode prompt.";
  }
  llama_batch_free(batch);

  std::string output;
  int32_t position = static_cast<int32_t>(prompt_tokens.size());
  for (int i = 0; i < max_tokens; ++i) {
    llama_token token = llama_sampler_sample(sampler, ctx, -1);
    if (llama_vocab_is_eog(vocab, token)) {
      break;
    }
    llama_sampler_accept(sampler, token);
    output += token_to_piece(vocab, token);

    std::vector<llama_token> next_tokens = {token};
    llama_batch next_batch = llama_batch_init(1, 0, 1);
    fill_batch(next_batch, next_tokens, position, true);
    position += 1;
    if (llama_decode(ctx, next_batch) != 0) {
      llama_batch_free(next_batch);
      break;
    }
    llama_batch_free(next_batch);
  }

  llama_sampler_free(sampler);
  llama_free(ctx);
  llama_model_free(model);
  return output;
}
#endif

jboolean runtimeReady(JNIEnv *, jobject) {
#if defined(ARMIN_LLAMA_GENERATE_READY)
  return JNI_TRUE;
#else
  return JNI_FALSE;
#endif
}

jstring generate(
    JNIEnv *env,
    jobject,
    jstring model_path,
    jstring prompt,
    jint max_tokens,
    jfloat temperature) {
#if defined(ARMIN_LLAMA_GENERATE_READY)
  const std::string result = generate_text(
      jstring_to_string(env, model_path),
      jstring_to_string(env, prompt),
      std::max<int>(1, std::min<int>(max_tokens, 2048)),
      temperature);
  return env->NewStringUTF(result.c_str());
#else
  const char *message =
      "Native llama.cpp runtime is not bundled. Add third_party/llama.cpp and "
      "a GGUF model before running native SLM smoke tests.";
  return env->NewStringUTF(message);
#endif
}

const JNINativeMethod kMethods[] = {
    {"runtimeReady", "()Z", reinterpret_cast<void *>(runtimeReady)},
    {"generate",
     "(Ljava/lang/String;Ljava/lang/String;IF)Ljava/lang/String;",
     reinterpret_cast<void *>(generate)},
};

}  // namespace

JNIEXPORT jint JNI_OnLoad(JavaVM *vm, void *) {
  JNIEnv *env = nullptr;
  if (vm->GetEnv(reinterpret_cast<void **>(&env), JNI_VERSION_1_6) != JNI_OK) {
    return JNI_ERR;
  }
  jclass bridge = env->FindClass("com/ironion/armin/NativeLlamaBridge");
  if (bridge == nullptr) {
    return JNI_ERR;
  }
  if (env->RegisterNatives(
          bridge,
          kMethods,
          sizeof(kMethods) / sizeof(kMethods[0])) != JNI_OK) {
    return JNI_ERR;
  }
  return JNI_VERSION_1_6;
}
