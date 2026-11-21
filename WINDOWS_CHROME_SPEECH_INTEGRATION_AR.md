# دمج خدمة Chrome للتعرف الصوتي في EMIS على Windows

## ما الذي تغير؟
- Windows: أصبحت `GoogleSpeechService` تستخدم Google Chrome عبر Web Speech API بلغة `ar-KW` بدلاً من الاعتماد على حزمة Speech Recognition المثبتة في Windows.
- Android: لم يتغير مسار MethodChannel / EventChannel.
- Linux وmacOS: يبقى مسار `speech_to_text` كما كان.
- اكتشاف Chrome يتم تلقائياً من مجلدات التثبيت المعتادة ثم من سجل Windows (App Paths).
- ينشئ التطبيق خادماً محلياً على loopback بمنفذ عشوائي، ويشغّل صفحة خدمة صغيرة داخل Chrome.
- النتائج النهائية فقط `final` ترسل إلى Flutter؛ لا ترسل النتائج الجزئية إلى الحقول.
- يستخدم Chrome ملف مستخدم منفصلاً في `%LOCALAPPDATA%\EMIS\ChromeSpeechProfile`.

## أول تشغيل وصلاحية الميكروفون
في أول تشغيل تكون نافذة Chrome مرئية حتى يتمكن المستخدم من الموافقة صراحةً على إذن الميكروفون. بعد وصول حدث بدء الاستماع، يحفظ التطبيق علامة محلية؛ وفي مرات التشغيل اللاحقة يفتح نافذة الخدمة خارج الشاشة.

## حدود يجب معرفتها
- هذا المسار يستخدم Web Speech API في Chrome، وليس واجهة Google Docs Voice Typing الرسمية أو API خاصة بها.
- قد يرسل Chrome الصوت إلى خدمة Google السحابية للتعرف عليه؛ لا تفترض أن المعالجة محلية أو تعمل دون إنترنت.
- يجب أن يكون Google Chrome مثبتاً على جهاز Windows. لا يتم تضمين Chrome داخل مثبت EMIS.
- هذه النسخة لم تُبنَ أو تُختبر على Windows داخل بيئة العمل الحالية. يجب تنفيذ Windows Release build واختبار دورة البدء/الإيقاف/الإلغاء على جهاز Windows قبل نشرها للمستخدمين.
