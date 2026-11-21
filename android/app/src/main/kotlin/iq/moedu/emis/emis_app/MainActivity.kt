package iq.moedu.emis.emis_app

import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.speech.RecognitionListener
import android.speech.RecognitionService
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import io.flutter.embedding.android.FlutterActivity
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream

class MainActivity : FlutterActivity() {
    private val methodChannelName = "emis.google_speech"
    private val eventChannelName = "emis.google_speech/events"
    private val googleQuickSearchPackage = "com.google.android.googlequicksearchbox"

    private val mainHandler = Handler(Looper.getMainLooper())
    private var recognizer: SpeechRecognizer? = null
    private var eventSink: EventChannel.EventSink? = null
    private var active = false
    private var explicitStop = false
    private var currentSessionId = 0
    private var currentLocale = "ar-IQ"
    private var currentEngine = "google"
    private var restartRunnable: Runnable? = null
    private var readyTimeoutRunnable: Runnable? = null
    private var recognizerReady = false
    private var autoRestart = false
    private var possibleSilenceMs = 23000L
    private var completeSilenceMs = 23000L
    private var minimumSpeechMs = 2500L
    private var restartDelayMs = 4100L

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, eventChannelName)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                }

                override fun onCancel(arguments: Any?) {
                    if (!active) {
                        eventSink = null
                    }
                }
            })

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "emis.local_model")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "copyBundledModel" -> {
                        val assetName = call.argument<String>("assetName")
                        val fileName = call.argument<String>("fileName")
                        if (assetName.isNullOrBlank() || fileName.isNullOrBlank() ||
                            fileName.contains("/") || fileName.contains("\\")) {
                            result.error("BAD_MODEL_PATH", "Invalid model asset path", null)
                        } else {
                            try {
                                val output = copyBundledModel(assetName, fileName)
                                result.success(output.absolutePath)
                            } catch (error: Exception) {
                                result.error("MODEL_COPY_FAILED", error.message, null)
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, methodChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getInfo" -> result.success(getRecognitionInfo())

                    "start" -> {
                        val sessionId = call.argument<Int>("sessionId") ?: 0
                        val locale = call.argument<String>("locale")?.takeIf { it.isNotBlank() } ?: "ar-IQ"
                        val engine = call.argument<String>("engine")?.takeIf { it.isNotBlank() } ?: "google"
                        autoRestart = call.argument<Boolean>("autoRestart") ?: false
                        possibleSilenceMs = (call.argument<Int>("possibleSilenceMs") ?: 23000).toLong().coerceIn(1000L, 90000L)
                        completeSilenceMs = (call.argument<Int>("completeSilenceMs") ?: 23000).toLong().coerceIn(1000L, 90000L)
                        minimumSpeechMs = (call.argument<Int>("minimumSpeechMs") ?: 2500).toLong().coerceIn(100L, 9000L)
                        restartDelayMs = (call.argument<Int>("restartDelayMs") ?: 4100).toLong().coerceIn(0L, 5000L)
                        startRecognition(sessionId, locale, engine, result)
                    }

                    "updateSettings" -> {
                        call.argument<Boolean>("autoRestart")?.let { autoRestart = it }
                        call.argument<Int>("possibleSilenceMs")?.let {
                            possibleSilenceMs = it.toLong().coerceIn(1000L, 90000L)
                        }
                        call.argument<Int>("completeSilenceMs")?.let {
                            completeSilenceMs = it.toLong().coerceIn(1000L, 90000L)
                        }
                        call.argument<Int>("minimumSpeechMs")?.let {
                            minimumSpeechMs = it.toLong().coerceIn(100L, 9000L)
                        }
                        call.argument<Int>("restartDelayMs")?.let {
                            restartDelayMs = it.toLong().coerceIn(0L, 5000L)
                        }
                        result.success(true)
                    }

                    "stop" -> {
                        stopRecognition(cancel = false)
                        result.success(true)
                    }

                    "cancel" -> {
                        stopRecognition(cancel = true)
                        result.success(true)
                    }

                    else -> result.notImplemented()
                }
            }
    }

    /** Copies a large GGUF asset in small chunks so it is never loaded fully in RAM. */
    private fun copyBundledModel(assetName: String, fileName: String): File {
        val lookupKey = FlutterInjector.instance().flutterLoader()
            .getLookupKeyForAsset(assetName)
        
        // التحقق من وجود الأصول في حال كان البناء بدون ذكاء اصطناعي
        val assetManager = assets
        try {
            assetManager.open(lookupKey).close()
        } catch (e: Exception) {
            throw IllegalStateException("Local AI model asset is not bundled in this build variant")
        }

        val output = File(filesDir, fileName)
        if (output.exists() && output.length() > 400_000_000L) return output

        val temporary = File(filesDir, "$fileName.tmp")
        assetManager.open(lookupKey).use { input ->
            FileOutputStream(temporary).use { outputStream ->
                val buffer = ByteArray(1024 * 1024)
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    outputStream.write(buffer, 0, count)
                }
                outputStream.fd.sync()
            }
        }
        if (temporary.length() < 400_000_000L) {
            temporary.delete()
            throw IllegalStateException("Bundled GGUF model is incomplete")
        }
        if (output.exists()) output.delete()
        if (!temporary.renameTo(output)) {
            temporary.copyTo(output, overwrite = true)
            temporary.delete()
        }
        return output
    }

    private fun defaultRecognitionService(): ComponentName? {
        val flattened = try {
            Settings.Secure.getString(
                contentResolver,
                "voice_recognition_service"
            )
        } catch (_: Exception) {
            null
        }
        return flattened?.takeIf { it.isNotBlank() }?.let {
            ComponentName.unflattenFromString(it)
        }
    }

    private fun allRecognitionServices(): List<ComponentName> {
        val intent = Intent(RecognitionService.SERVICE_INTERFACE)
        val services = try {
            if (android.os.Build.VERSION.SDK_INT >= 33) {
                packageManager.queryIntentServices(
                    intent,
                    PackageManager.ResolveInfoFlags.of(0L)
                )
            } else {
                @Suppress("DEPRECATION")
                packageManager.queryIntentServices(intent, 0)
            }
        } catch (_: Exception) {
            emptyList()
        }

        return services.mapNotNull { info ->
            val service = info.serviceInfo ?: return@mapNotNull null
            ComponentName(service.packageName, service.name)
        }
    }

    private fun findGoogleRecognitionService(): ComponentName? {
        val services = allRecognitionServices()
        val default = defaultRecognitionService()

        if (default != null && default.packageName.startsWith("com.google.android")) {
            return default
        }

        services.firstOrNull { it.packageName == googleQuickSearchPackage }?.let { return it }
        services.firstOrNull { it.packageName.startsWith("com.google.android") }?.let { return it }

        return null
    }

    private fun getRecognitionInfo(): Map<String, Any?> {
        val default = defaultRecognitionService()
        val google = findGoogleRecognitionService()
        val frameworkAvailable = try {
            SpeechRecognizer.isRecognitionAvailable(this)
        } catch (_: Exception) {
            false
        }

        val effective = google ?: default
        val provider = when {
            effective?.packageName?.startsWith("com.google.android") == true -> "Google"
            effective != null -> "النظام / مزود التعرف الافتراضي"
            else -> ""
        }

        return mapOf(
            "available" to (frameworkAvailable && effective != null),
            "frameworkAvailable" to frameworkAvailable,
            "package" to (effective?.packageName ?: ""),
            "service" to (effective?.className ?: ""),
            "defaultPackage" to (default?.packageName ?: ""),
            "defaultService" to (default?.className ?: ""),
            "googleAvailable" to (google != null),
            "googlePackage" to (google?.packageName ?: ""),
            "googleService" to (google?.className ?: ""),
            "provider" to provider,
        )
    }

    private fun createRecognizer(engine: String): SpeechRecognizer? {
        val service = if (engine == "google") findGoogleRecognitionService() else null
        if (engine == "google" && service == null) return null

        return try {
            if (service != null) {
                SpeechRecognizer.createSpeechRecognizer(this, service)
            } else {
                SpeechRecognizer.createSpeechRecognizer(this)
            }.also {
                it.setRecognitionListener(recognitionListener)
            }
        } catch (_: Exception) {
            null
        }
    }

    private fun ensureRecognizer(engine: String): Boolean {
        if (recognizer != null && currentEngine == engine) return true

        try {
            recognizer?.cancel()
            recognizer?.destroy()
        } catch (_: Exception) {
        }
        recognizer = createRecognizer(engine)
        currentEngine = engine
        return recognizer != null
    }

    private fun startRecognition(
        sessionId: Int,
        locale: String,
        engine: String,
        result: MethodChannel.Result,
    ) {
        if (!SpeechRecognizer.isRecognitionAvailable(this)) {
            emit("error", sessionId, mapOf("message" to "لا توجد خدمة تعرف صوتي متاحة على الجهاز."))
            result.success(false)
            return
        }

        val requestedEngine = if (engine == "legacy") "google" else "google"

        if (requestedEngine == "google" && findGoogleRecognitionService() == null) {
            emit("error", sessionId, mapOf("message" to "خدمة Google Speech Recognition غير متاحة أو غير مفعّلة على هذا الجهاز. فعّل تطبيق Google للتعرف على الكلام ثم أعد المحاولة."))
            result.success(false)
            return
        }

        cancelScheduledRestart()
        active = true
        explicitStop = false
        currentSessionId = sessionId
        currentLocale = locale
        currentEngine = requestedEngine

        try {
            // Do not reuse a recognizer that may still be completing a previous
            // cancel/stop operation. A fresh instance avoids intermittent BUSY
            // and early-session termination on several Android speech providers.
            destroyRecognizer()
            recognizer = createRecognizer(requestedEngine)
            if (recognizer == null) {
                active = false
                emit("error", sessionId, mapOf("message" to "تعذر تهيئة محرك التعرف الصوتي."))
                result.success(false)
                return
            }
            result.success(true)
            mainHandler.postDelayed({
                if (active && !explicitStop && currentSessionId == sessionId) {
                    startListeningInternal()
                }
            }, 180L)
        } catch (e: Exception) {
            active = false
            emit("error", sessionId, mapOf("message" to (e.message ?: "تعذر بدء التعرف الصوتي.")))
            result.success(false)
        }
    }

    private fun startListeningInternal() {
        if (!active || explicitStop) return

        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, currentLocale)
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_PREFERENCE, currentLocale)
            putExtra(RecognizerIntent.EXTRA_ONLY_RETURN_LANGUAGE_PREFERENCE, false)
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 5)
            putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, false)
            putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS, completeSilenceMs.toInt())
            putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_POSSIBLY_COMPLETE_SILENCE_LENGTH_MILLIS, possibleSilenceMs.toInt())
            putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_MINIMUM_LENGTH_MILLIS, minimumSpeechMs.toInt())
        }
        try {
            recognizerReady = false
            recognizer?.startListening(intent)
            emit("starting", currentSessionId, emptyMap())
            cancelReadyTimeout()
            val session = currentSessionId
            readyTimeoutRunnable = Runnable {
                readyTimeoutRunnable = null
                if (active && !explicitStop && !recognizerReady && session == currentSessionId) {
                    emit("recovering", session, mapOf("reason" to "ready_timeout", "message" to "تأخر تشغيل الميكروفون، تجري إعادة المحاولة."))
                    scheduleRestart(450L)
                }
            }
            mainHandler.postDelayed(readyTimeoutRunnable!!, 8000L)
        } catch (e: Exception) {
            emit("recovering", currentSessionId, mapOf("reason" to "start_failed", "message" to (e.message ?: "تعذر بدء الاستماع، تجري إعادة المحاولة.")))
            scheduleRestart(500L)
        }
    }

    private fun stopRecognition(cancel: Boolean) {
        explicitStop = true
        active = false
        cancelScheduledRestart()
        cancelReadyTimeout()
        try {
            if (cancel) recognizer?.cancel() else recognizer?.stopListening()
        } catch (_: Exception) {
        }
        emit("stopped", currentSessionId, emptyMap())
    }

    private fun scheduleRestart(delayMs: Long) {
        if (!active || explicitStop) return
        cancelReadyTimeout()
        cancelScheduledRestart()
        val session = currentSessionId
        restartRunnable = Runnable {
            restartRunnable = null
            if (active && !explicitStop && session == currentSessionId) {
                destroyRecognizer()
                recognizer = createRecognizer(currentEngine)
                if (recognizer == null) {
                    active = false
                    emit("error", currentSessionId, mapOf("message" to "تعذر إعادة تشغيل خدمة التعرف الصوتي."))
                    emit("stopped", currentSessionId, emptyMap())
                    return@Runnable
                }
                mainHandler.postDelayed({
                    if (active && !explicitStop && session == currentSessionId) {
                        startListeningInternal()
                    }
                }, 180L)
            }
        }
        mainHandler.postDelayed(restartRunnable!!, delayMs)
    }

    private fun cancelScheduledRestart() {
        restartRunnable?.let { mainHandler.removeCallbacks(it) }
        restartRunnable = null
    }

    private fun cancelReadyTimeout() {
        readyTimeoutRunnable?.let { mainHandler.removeCallbacks(it) }
        readyTimeoutRunnable = null
    }

    private fun destroyRecognizer() {
        try {
            recognizer?.cancel()
            recognizer?.destroy()
        } catch (_: Exception) {
        }
        recognizer = null
        recognizerReady = false
    }

    private fun emit(type: String, sessionId: Int, data: Map<String, Any?>) {
        val payload = HashMap<String, Any?>()
        payload["type"] = type
        payload["sessionId"] = sessionId
        payload.putAll(data)
        mainHandler.post { eventSink?.success(payload) }
    }

    private val recognitionListener = object : RecognitionListener {
        override fun onReadyForSpeech(params: Bundle?) {
            recognizerReady = true
            cancelReadyTimeout()
            emit("ready", currentSessionId, emptyMap())
        }

        override fun onBeginningOfSpeech() {
            emit("begin", currentSessionId, emptyMap())
        }

        override fun onRmsChanged(rmsdB: Float) {
            emit("level", currentSessionId, mapOf("rms" to rmsdB))
        }

        override fun onBufferReceived(buffer: ByteArray?) {}

        override fun onEndOfSpeech() {
            emit("endOfSpeech", currentSessionId, emptyMap())
        }

        override fun onError(error: Int) {
            if (!active || explicitStop) return
            cancelReadyTimeout()
            val noSpeechYet = error == SpeechRecognizer.ERROR_NO_MATCH ||
                error == SpeechRecognizer.ERROR_SPEECH_TIMEOUT
            val isBusy = error == SpeechRecognizer.ERROR_RECOGNIZER_BUSY
            val recoverable = noSpeechYet ||
                isBusy ||
                error == SpeechRecognizer.ERROR_NETWORK ||
                error == SpeechRecognizer.ERROR_NETWORK_TIMEOUT ||
                error == SpeechRecognizer.ERROR_SERVER ||
                error == SpeechRecognizer.ERROR_SERVER_DISCONNECTED

            // Silence/no-match and transient BUSY state must never close an active dictation session.
            // Network/server retries continue to respect the user's auto-restart
            // preference; permission/audio/language errors remain terminal.
            if (noSpeechYet || isBusy || (autoRestart && recoverable)) {
                emit("recovering", currentSessionId, mapOf(
                    "code" to error,
                    "reason" to if (noSpeechYet) "no_speech" else "recognizer_error",
                    "message" to speechErrorMessage(error)
                ))
                scheduleRestart(if (noSpeechYet || isBusy) 450L else restartDelayMs.coerceAtLeast(500L))
            } else {
                emit("error", currentSessionId, mapOf("code" to error, "message" to speechErrorMessage(error)))
                active = false
                cancelScheduledRestart()
                cancelReadyTimeout()
                emit("stopped", currentSessionId, emptyMap())
            }
        }

        override fun onResults(results: Bundle?) {
            cancelReadyTimeout()
            val values = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION).orEmpty()
            val confidences = results?.getFloatArray(SpeechRecognizer.CONFIDENCE_SCORES)
            val text = values.firstOrNull { it.isNotBlank() }?.trim().orEmpty()
            emit(
                "result",
                currentSessionId,
                mapOf(
                    "text" to text,
                    "segment" to text,
                    "alternates" to values,
                    "segmentAlternates" to values,
                    "confidences" to (confidences?.toList() ?: emptyList<Float>())
                )
            )
            if (active && !explicitStop) {
                if (autoRestart) {
                    scheduleRestart(restartDelayMs)
                } else {
                    active = false
                    emit("stopped", currentSessionId, emptyMap())
                }
            }
        }

        override fun onPartialResults(partialResults: Bundle?) {
            val values = partialResults?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION).orEmpty()
            val text = values.firstOrNull { it.isNotBlank() }?.trim().orEmpty()
            if (text.isNotEmpty()) {
                emit(
                    "partial",
                    currentSessionId,
                    mapOf(
                        "text" to text,
                        "segment" to text,
                        "alternates" to values,
                        "segmentAlternates" to values
                    )
                )
            }
        }

        override fun onEvent(eventType: Int, params: Bundle?) {}
    }

    private fun speechErrorMessage(code: Int): String = when (code) {
        SpeechRecognizer.ERROR_AUDIO -> "تعذر الوصول إلى الميكروفون."
        SpeechRecognizer.ERROR_CLIENT -> "حدث خطأ في خدمة التعرف الصوتي."
        SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "لم يتم منح صلاحية الميكروفون."
        SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED -> "اللغة العربية غير مدعومة في خدمة التعرف الحالية."
        SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE -> "اللغة العربية غير متاحة حالياً في خدمة التعرف."
        SpeechRecognizer.ERROR_NETWORK,
        SpeechRecognizer.ERROR_NETWORK_TIMEOUT -> "تعذر الاتصال بخدمة التعرف على الكلام."
        SpeechRecognizer.ERROR_NO_MATCH -> "لم يتم التعرف على الكلام."
        SpeechRecognizer.ERROR_RECOGNIZER_BUSY -> "خدمة التعرف مشغولة، ستتم إعادة المحاولة تلقائياً."
        SpeechRecognizer.ERROR_SERVER,
        SpeechRecognizer.ERROR_SERVER_DISCONNECTED -> "حدث خطأ في خادم التعرف على الكلام."
        SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> "لم يتم سماع كلام واضح، ستتم إعادة المحاولة تلقائياً."
        else -> "خطأ في التعرف الصوتي (رمز $code)."
    }

    override fun onDestroy() {
        active = false
        explicitStop = true
        cancelScheduledRestart()
        cancelReadyTimeout()
        destroyRecognizer()
        super.onDestroy()
    }
}
