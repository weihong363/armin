# Native SLM llama.cpp Smoke

目的：验证 Armin Android App 可以通过 native runtime 在设备侧调用本地 SLM，而不是只调用远端 AI API。

当前接入状态：

- Flutter 侧已新增 `NativeSlmClient`，通过 `com.ironion.armin/native_slm` MethodChannel 调用 Android。
- Android 侧已新增 `libarmin_llama_jni.so` native 库构建入口和 `NativeLlamaBridge`。
- Android native runtime 已接入 llama.cpp，可加载 GGUF 并生成文本。

默认模型路径：

```text
/data/user/0/com.ironion.armin/files/slm/model.gguf
```

本地模型缓存：

```text
.models/slm/Qwen3-0.6B-Q4_K_M.gguf
```

模型放置：

```bash
DEVICE=emulator-5554 ./scripts/slm/push-gguf-model.sh .models/slm/Qwen3-0.6B-Q4_K_M.gguf
```

真机 / 模拟器 smoke：

```bash
flutter drive \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/native_slm_smoke_test.dart \
  -d emulator-5554
```

通过标准：

- `NativeSlmClient.capability()` 返回 available。
- `NativeSlmClient.generate()` 返回包含 `ARMIN_NATIVE_SLM_SMOKE status=PASS` 的文本。
- 失败时必须明确报告 native runtime 或模型文件缺失，不允许 fallback 被记为 native SLM PASS。
