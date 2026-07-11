package com.ironion.armin

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.ironion.armin/native_slm"
        ).setMethodCallHandler { call, result ->
            NativeSlmChannel.handle(call, result)
        }
    }
}

private object NativeSlmChannel {
    private const val DEFAULT_MODEL_PATH = "/data/local/tmp/armin/slm/model.gguf"
    private const val BACKEND = "llama.cpp"

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "capability" -> result.success(capability(call.modelPath()))
            "generate" -> generate(call, result)
            else -> result.notImplemented()
        }
    }

    private fun capability(modelPath: String): Map<String, Any?> {
        val model = File(modelPath)
        if (!NativeLlamaBridge.libraryLoaded) {
            return mapOf(
                "available" to false,
                "message" to "未加载 llama.cpp native runtime：libarmin_llama_jni.so。",
                "backend" to BACKEND,
                "modelPath" to modelPath,
            )
        }
        if (!NativeLlamaBridge.runtimeReady()) {
            return mapOf(
                "available" to false,
                "message" to "llama.cpp native runtime 尚未接入生成能力。",
                "backend" to BACKEND,
                "modelPath" to modelPath,
            )
        }
        if (!model.isFile) {
            return mapOf(
                "available" to false,
                "message" to "未找到端侧模型文件：$modelPath。",
                "backend" to BACKEND,
                "modelPath" to modelPath,
            )
        }
        return mapOf(
            "available" to true,
            "message" to "端侧 llama.cpp 模型已就绪。",
            "backend" to BACKEND,
            "modelPath" to modelPath,
        )
    }

    private fun generate(call: MethodCall, result: MethodChannel.Result) {
        val allowUnsafeDecode = call.argument<Boolean>("allowUnsafeDecode") == true
        if (!allowUnsafeDecode) {
            result.error(
                "native_slm_decode_disabled",
                "端侧 llama.cpp decode 默认关闭，避免 native abort 导致应用退出。",
                null,
            )
            return
        }
        val prompt = call.argument<String>("prompt")?.trim().orEmpty()
        if (prompt.isEmpty()) {
            result.error("invalid_prompt", "Prompt is empty.", null)
            return
        }
        val modelPath = call.modelPath()
        val current = capability(modelPath)
        if (current["available"] != true) {
            result.error("native_slm_unavailable", current["message"] as String, current)
            return
        }
        val maxTokens = call.argument<Int>("maxTokens") ?: 512
        val temperature = (call.argument<Double>("temperature") ?: 0.2).toFloat()
        Thread {
            try {
                val text = NativeLlamaBridge.generate(
                    modelPath,
                    prompt,
                    maxTokens.coerceIn(1, 2048),
                    temperature.coerceIn(0.0f, 1.5f),
                )
                result.success(
                    mapOf(
                        "text" to text,
                        "backend" to BACKEND,
                        "modelPath" to modelPath,
                    )
                )
            } catch (error: Throwable) {
                result.error(
                    "native_slm_failed",
                    error.message ?: "Native SLM generation failed.",
                    null,
                )
            }
        }.start()
    }

    private fun MethodCall.modelPath(): String {
        return argument<String>("modelPath")?.takeIf { it.isNotBlank() } ?: DEFAULT_MODEL_PATH
    }
}

private object NativeLlamaBridge {
    val libraryLoaded: Boolean = runCatching {
        System.loadLibrary("armin_llama_jni")
    }.isSuccess

    external fun generate(
        modelPath: String,
        prompt: String,
        maxTokens: Int,
        temperature: Float,
    ): String

    external fun runtimeReady(): Boolean
}
