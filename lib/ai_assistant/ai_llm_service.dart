import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:llamafu/llamafu.dart';
import 'package:path_provider/path_provider.dart';

/// Local GGUF inference only. This service never sends text to a network.
class AiLlmService {
  AiLlmService._();
  static final AiLlmService instance = AiLlmService._();

  static const String modelAsset =
      'assets/models/qwen2.5-0.5b-instruct-q4_k_m.gguf';
  static const String modelFileName =
      'qwen2.5-0.5b-instruct-q4_k_m.gguf';

  Llamafu? _runtime;
  Future<void>? _loading;
  bool _generating = false;
  String? lastError;

  bool get isLoaded => _runtime != null;
  bool get isGenerating => _generating;

  /// Copies the bundled model to app-private storage once, then opens it.
  /// The model is intentionally not downloaded at runtime.
  Future<bool> initialize() async {
    if (_runtime != null) return true;
    if (_loading != null) {
      await _loading;
      return _runtime != null;
    }
    final completer = _initializeInternal();
    _loading = completer;
    try {
      await completer;
    } finally {
      _loading = null;
    }
    return _runtime != null;
  }

  Future<String> _resolveModelPath() async {
    if (Platform.isAndroid) {
      // Native Android copies the APK asset with a streaming buffer. This
      // avoids holding a 491 MB model in Dart memory during first launch.
      final modelPath = await const MethodChannel('emis.local_model')
          .invokeMethod<String>('copyBundledModel', <String, String>{
        'assetName': modelAsset,
        'fileName': modelFileName,
      });
      if (modelPath != null && modelPath.isNotEmpty) {
        return modelPath;
      }
    }

    // على Windows / سطح المكتب: التحقق أولاً من مجلد بيانات التطبيق أو مجلد التشغيل المباشر
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final bundledCandidates = <String>[
      '$exeDir${Platform.pathSeparator}data${Platform.pathSeparator}flutter_assets${Platform.pathSeparator}assets${Platform.pathSeparator}models${Platform.pathSeparator}$modelFileName',
      '$exeDir${Platform.pathSeparator}assets${Platform.pathSeparator}models${Platform.pathSeparator}$modelFileName',
    ];
    for (final candidate in bundledCandidates) {
      final f = File(candidate);
      if (await f.exists() && await f.length() >= 400000000) {
        return f.path;
      }
    }

    final supportDir = await getApplicationSupportDirectory();
    final targetFile =
        File('${supportDir.path}${Platform.pathSeparator}$modelFileName');
    if (await targetFile.exists() && await targetFile.length() >= 400000000) {
      return targetFile.path;
    }

    final data = await rootBundle.load(modelAsset);
    await targetFile.parent.create(recursive: true);
    await targetFile.writeAsBytes(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      flush: true,
    );
    return targetFile.path;
  }

  Future<void> _initializeInternal() async {
    try {
      final modelPath = await _resolveModelPath();
      if (modelPath.isEmpty ||
          !await File(modelPath).exists() ||
          await File(modelPath).length() < 400000000) {
        throw StateError('ملف نموذج الذكاء الاصطناعي غير موجود داخل التطبيق.');
      }

      final processors = Platform.numberOfProcessors;
      final threads = math.max(1, math.min(4, processors - 1));
      _runtime = await Llamafu.init(
        modelPath: modelPath,
        threads: threads,
        // A conservative context avoids exhausting memory on lower-end phones.
        contextSize: 2048,
      );
      lastError = null;
    } catch (error) {
      lastError = error.toString();
      try {
        _runtime?.close();
      } catch (_) {}
      _runtime = null;
    }
  }

  Future<Map<String, dynamic>?> extractFields({
    required String utterance,
    required String target,
    required Map<String, String> currentDraft,
    required List<String> allowedFields,
  }) async {
    if (_generating) return null;
    if (_runtime == null) {
      final ready = await initialize();
      if (!ready) return null;
    }
    _generating = true;
    try {
      final prompt = _buildPrompt(
        utterance: utterance,
        target: target,
        currentDraft: currentDraft,
        allowedFields: allowedFields,
      );
      final raw = await _runtime!.complete(
        prompt: prompt,
        maxTokens: 512,
        temperature: 0.05,
      );
      final decoded = _decodeJson(raw);
      if (decoded == null) return null;
      final result = <String, dynamic>{};
      final entities = decoded['entities'];
      if (entities is Map) {
        for (final entry in entities.entries) {
          final key = entry.key.toString();
          final value = entry.value;
          if (allowedFields.contains(key) &&
              value is String &&
              value.trim().isNotEmpty) {
            result[key] = value.trim();
          }
        }
      }
      final intent = decoded['intent'];
      if (intent is String) result['_intent'] = intent;
      return result;
    } catch (error) {
      lastError = error.toString();
      return null;
    } finally {
      _generating = false;
    }
  }

  String _buildPrompt({
    required String utterance,
    required String target,
    required Map<String, String> currentDraft,
    required List<String> allowedFields,
  }) {
    final keys = allowedFields.join(', ');
    return '''<|im_start|>system
أنت مستخرج بيانات لاستمارة $target في نظام EMIS العراقي. اقرأ الكلام باللهجة العراقية كما هو، واستخرج فقط المعلومات المذكورة صراحة في رسالة المستخدم الحالية. أعد JSON صالحاً فقط: {"intent":"addStudent أو addTeacher أو unknown","entities":{}}.
المفاتيح المسموحة فقط: $keys.
معاني الحقول المهمة:
- name وfatherName وgrandFatherName وfathersGrandFatherName وsurName: أجزاء اسم الشخص بالترتيب.
- motherName وmothersFatherName وmothersGrandFatherName: أجزاء اسم الأم.
- dateOfBirth: تاريخ التولد، issuingDate: تاريخ إصدار الوثيقة، dateOfStartWorking: تاريخ أول تعيين.
- nationalId: البطاقة الوطنية، idNumber: هوية الأحوال المدنية، employeeIdNumber: الرقم الوظيفي، familyNumber: الرقم العائلي.
- homePhoneNumber للطالب، mobilePhoneNumber للمعلم، emergencyContactPhoneNumber لهاتف الطوارئ.
- town وarea وquarter وstreet وaddress1 وaddress2 وclosestLocation: تفاصيل السكن.
- addressGovernorate وaddressDistrict وaddressTown: المحافظة والقضاء والناحية.
- stageId وclassRoomId: الصف والشعبة للطالب.
- universityName وgraduationYear وspecialization وeducationLevel: بيانات التحصيل الدراسي للمعلم.
- positionType: العنوان الوظيفي، currentPosition: المنصب الحالي، jobDesignation: المسمى الوظيفي.
قواعد إلزامية:
1. لا تملأ أي حقل اعتماداً على قيمة افتراضية أو معلومة سابقة أو تخمين.
2. لا تنقل قيمة من حقل إلى حقل مشابه؛ ميّز بين العنوان الوظيفي والمنصب الحالي، وبين تاريخ الميلاد وتاريخ الإصدار.
3. إذا صحح المستخدم قيمة، استخرج القيمة الجديدة فقط للحقل المقصود.
4. حوّل الأرقام المنطوقة إلى أرقام لاتينية مع الحفاظ على ترتيبها، ولا تجمع أرقام حقول مختلفة.
5. أعد التواريخ بصيغة yyyy-mm-dd بعد التأكد من صحتها؛ وإلا اتركها.
6. لا تنشئ معرفات للقوائم المنسدلة. أعد اسم الخيار كما نطق.
7. إذا لم تعرف الحقل أو كانت العبارة ملتبسة، اتركه فارغاً ولا تخترع قيمة.
8. كل قيمة في entities نص. لا تضف شرحاً أو Markdown.
<|im_end|>
<|im_start|>user
رسالة المستخدم: $utterance
أعد JSON فقط.
<|im_end|>
<|im_start|>assistant
''';
  }

  Map<String, dynamic>? _decodeJson(String raw) {
    var value = raw.trim();
    value = value.replaceAll(RegExp(r'^```(?:json)?\s*', caseSensitive: false), '');
    value = value.replaceAll(RegExp(r'\s*```$'), '').trim();
    final start = value.indexOf('{');
    final end = value.lastIndexOf('}');
    if (start < 0 || end <= start) return null;
    try {
      final decoded = jsonDecode(value.substring(start, end + 1));
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  void dispose() {
    try {
      _runtime?.close();
    } catch (_) {}
    _runtime = null;
  }
}
