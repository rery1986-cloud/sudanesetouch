# إعداد Supabase لمنصة لمسة سودانيز Touch

## 1) إعداد المشروع
1. أنشئي مشروعاً في Supabase ثم افتحي **SQL Editor** وشغّلي `supabase-schema.sql`.
2. انسخي Project URL و`anon`/publishable key إلى `supabase-config.js`. المفتاح العام فقط مسموح في الواجهة.
3. لا تضعي `service_role`, مفاتيح Edge Function، أو كلمات مرور في ملفات الواجهة أو GitHub. أضيفي الأسرار إلى إعدادات Supabase Edge Functions فقط.
4. فعّلي تأكيد البريد الإلكتروني واضبطي Redirect URLs لتشمل عنوان الموقع وصفحة قبول الدعوة.
5. أنشئي Storage buckets خاصة/عامة بحسب سياسة الصور، واض��طي سياسات الرفع بحيث يرفع التاجر إلى مساره فقط. لا ترفعي بيانات شخصية حساسة للعامة.

## 2) دمج الواجهة الحالية
الملف الأصلي `index.html` يحتوي واجهة كبيرة مضمنة. أضيفي قبل سكربت التطبيق الحالي (أو قبل `</body>`) هذه السكربتات مع بقاء التصميم وRTL كما هما:

```html
<script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2"></script>
<script src="./supabase-config.js"></script>
<script src="./lamsa-enhancements.js"></script>
```

ثم أنشئي العميل مرة واحدة: `window.lamsaSupabase = window.createLamsaSupabaseClient()`.
واجهات المصادقة والبيانات في `lamsa-enhancements.js` متاحة عبر `window.LamsaTouch`; اربطيها بنماذج وتوجيهات التطبيق الحالية. لا تُستبدل بيانات العروض أو الحجوزات القديمة بها قبل ترحيلها.

## 3) التسجيل والدخول
- التسجيل الحقيقي: Supabase Auth email/password. اختيار الدور العام محدود إلى `client`, `provider`, `merchant`، وتُنشأ `profiles` تلقائياً بالـ trigger.
- `admin` و`moderator` لا يمكن طلبهما من واجهة التسجيل. يُمنح moderator عند قبول دعوة صالحة فقط.
- المستخدمون التجريبيون القدامى يظلون تجريبيين ولا ينبغي مزجهم مع الحسابات الحقيقية؛ لا تحفظي كلمات مرور تجريبية أو حقيقية في localStorage.

## 4) دعوات الأدمن والأمان
أنشئي Edge Function لإصدار الدعوات باسم `admin-invitations` قبل إتاحة زر الدعوة. يجب أن تتحقق الدالة من جلسة المستخدم و`profiles.role='admin'` وادعاء `app_metadata.platform_super_admin=true`، وتُنشئ token عشوائياً باستخدام `crypto.getRandomValues`، وتحفظ فقط SHA-256 digest في `admin_invitations`, ثم تعيد الرابط مرة واحدة. أسرار الخدمة في Edge Function environment فقط. لا تمنحي المستخدمين صلاحية قراءة جدول الدعوات.

قبول الدعوة: يسجل المدعو بالبريد المطابق باستخدام `signUp`، يحدد كلمة المرور مرتين في النموذج، ثم يستدعي `accept_admin_invitation(raw_token, phone)` أثناء تسجيل الدخول. RPC تتحقق من البريد والانتهاء وعدم الاستخدام وتحوّل الحساب إلى moderator مرة واحدة. لا ترسلي كلمة المرور إلى RPC أو سجليها.

### تهيئة مديرة النظام الأولى
بعد إنشاء حساب Auth موثوق، امنحيه `app_metadata.platform_super_admin=true` من بيئة الإدارة الموثوقة (Supabase Dashboard/Admin API). لا تضعي service role key في SQL client أو المتصفح. لا توجد كلمة مرور افتراضية.

## 5) المدن والصلاحيات
`countries` يحتوي الدول والمدن المطلوبة. سياسات RLS تفصل إدارة الملف عن النطاق العام؛ حقل `country` و`city` للأدمن يحدد النطاق. خصّصي أدوار moderator وصلاحياتهم من قناة إدارة موثوقة فقط؛ لا تسمحي للأدمن المحلي بإدارة الأدمنز.

## 6) التحقق قبل الإنتاج
شغّلي سيناريوهات التسجيل للعميلة ومقدمة الخدمة والتاجرة، إنشاء/إدارة إعلان كتاجرة، اختبار منع تغيير role، إنشاء/قبول/إعادة استخدام دعوة، تغيير كلمة مرور عبر `auth.updateUser`, اختبار نطاق moderator، وفحص RLS بحسابات منفصلة. لا يمكن اعتبار اختبارات الإنتاج مكتملة قبل إعداد مشروع Supabase فعلي وربط الواجهة وإعداد Edge Function.
