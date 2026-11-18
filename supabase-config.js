// Browser-safe Supabase configuration. The anon/publishable key is public by design;
// RLS is the security boundary. Never add a service_role or secret key here.
window.LAMSA_SUPABASE_CONFIG = Object.freeze({
  url: 'https://YOUR_PROJECT_ID.supabase.co',
  anonKey: 'YOUR_SUPABASE_PUBLISHABLE_OR_ANON_KEY'
});

window.getLamsaSupabaseConfigError = function () {
  const { url, anonKey } = window.LAMSA_SUPABASE_CONFIG || {};
  if (!url || !anonKey || /YOUR_PROJECT_ID|YOUR_/.test(url + anonKey)) {
    return 'لربط الحسابات الحقيقية، أضيفي رابط مشروع Supabase ومفتاح anon/publishable في ملف supabase-config.js. يمكنك متابعة وضع العرض التجريبي.';
  }
  if (!/^https:\/\/[a-z0-9-]+\.supabase\.co$/i.test(url)) return 'رابط Supabase غير صالح. تحققي من Project URL في إعدادات المشروع.';
  if (!window.supabase?.createClient) return 'تعذّر تحميل مكتبة Supabase. تحققي من اتصال الإنترنت ثم أعيدي المحاولة.';
  return '';
};

window.createLamsaSupabaseClient = function () {
  const problem = window.getLamsaSupabaseConfigError();
  if (problem) throw new Error(problem);
  const { url, anonKey } = window.LAMSA_SUPABASE_CONFIG;
  return window.supabase.createClient(url, anonKey, {
    auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true }
  });
};
