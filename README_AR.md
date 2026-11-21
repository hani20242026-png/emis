# حزمة Workflow مدمجة لإصلاح استعادة llama.cpp

هذه الحزمة تحتوي على **ملف build_apk.yml كاملاً بعد التعديل**، وليس مجرد خطوة منفصلة.

## الملفات ومواقعها

1. `.github/workflows/build_apk.yml`
   استبدل به ملف Workflow الحالي بالكامل.
2. `scripts/restore_llama_cpp.py`
   ضعه في مجلد `scripts` بجذر المشروع.

## ما الذي تم تعديله؟

أُخذ ملف Workflow من نسخة المشروع التي أرفقتها، ثم أُضيفت خطوة استعادة llama.cpp مباشرة بعد:
`Patch llamafu Android Gradle compatibility`

وقبل فك مفتاح التوقيع وبناء APK.

الخطوة تنفذ:
`python3 scripts/restore_llama_cpp.py`

السكربت يقرأ مسار Pub Cache من `PUB_CACHE` ويحسب المسار المطلوب حرفياً من تعبير CMake داخل llamafu:
`android/../../../llama.cpp`

وهذا يحل المسار إلى:
`<PUB_CACHE>/hosted/llama.cpp`

ثم ينزّل مصدر llama.cpp عند commit المثبت `b96b82f`، ويضعه في المسار الصحيح ويتحقق من:
- `CMakeLists.txt`
- `ggml/`
- `src/`

## طريقة التطبيق من الهاتف

- فك ضغط الحزمة.
- ارفع الملف `build_apk.yml` إلى `.github/workflows/build_apk.yml` مع استبدال القديم.
- ارفع `restore_llama_cpp.py` إلى `scripts/restore_llama_cpp.py`.
- لا تحذف `scripts/patch_llamafu_android.py` الموجود في مشروعك.
- شغّل GitHub Actions يدوياً.

## ملاحظة
تم الإبقاء على بقية إعدادات Workflow الموجودة في نسخة المشروع المرفقة كما هي، بما فيها Flutter 3.47.6، NDK 28.2.13676358، إعداد تنزيل النموذج، التوقيع، ورفع APK.

لم يتم تنفيذ بناء APK فعلي في هذه البيئة؛ لذلك نجاح البناء النهائي يحتاج تأكيد GitHub Actions.
