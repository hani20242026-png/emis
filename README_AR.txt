تحديث Windows لمشروع EMIS

الملفات:
1) .github/workflows/build_windows.yml
   - حفظ app_icon.ico قبل إعادة إنشاء مجلد windows ثم إعادته.
   - التحقق من أن Runner.rc يشير إلى الأيقونة الأصلية.
   - إنشاء مُثبّت Windows بصيغة EMIS-Setup.exe باستخدام Inno Setup.
   - إضافة خيار اختصار سطح المكتب (غير محدد افتراضياً).
   - إضافة GitHub Artifact Attestation لإثبات مصدر البناء.

2) lib/google_speech_service.dart
   - تشغيل نافذة Chrome المساعدة خارج الشاشة في كل مرة، بدلاً من إظهارها عند التشغيل الأول فقط.
   - لا يزال Chrome يعمل بواجهة app مخفية خارج الشاشة وليس headless.

3) installer/EMIS-Setup.iss
   - تثبيت داخل Program Files.
   - إنشاء اختصار قائمة ابدأ.
   - خيار اختياري لإنشاء اختصار سطح المكتب.
   - إلغاء تثبيت قياسي من Windows.

ملاحظات مهمة:
- استبدل الملفات الثلاثة في المستودع مع الحفاظ على المسارات.
- شغّل GitHub Actions يدوياً. الناتج سيكون Artifact باسم EMIS-Windows-Installer ويحتوي EMIS-Setup.exe.
- لم يتم توقيع EXE بشهادة Authenticode؛ Artifact Attestation ليس شهادة ناشر Windows.
- لم يتم إجراء بناء Windows فعلي في هذه البيئة، لذلك يجب اعتماد نتيجة GitHub Actions واختبار المُثبّت على Windows.
- لم يتضمن هذا التحديث معالجة شاملة لألوان جميع الشاشات؛ هذه تحتاج مراجعة مستقلة لكل مكوّن لتفادي إفساد ألوان الأزرار والبطاقات ذات الخلفيات الملونة.
