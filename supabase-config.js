// Browser-safe Supabase configuration. The anon/publishable key is public by design;
// RLS is the security boundary. Never add a service_role or secret key here.
window.LAMSA_SUPABASE_CONFIG = Object.freeze({
  url: 'https://YOUR_PROJECT_ID.supabase.co',
  anonKey: 'YOUR_SUPABASE_PUBLISHABLE_OR_ANON_KEY'
});

// Load this file before lamsa-enhancements.js and include Supabase JS v2 UMD CDN.
window.createLamsaSupabaseClient = function () {
  const { url, anonKey } = window.LAMSA_SUPABASE_CONFIG || {};
  if (!url || !anonKey || url.includes('YOUR_PROJECT_ID') || anonKey.includes('YOUR_')) {
    throw new Error('أضيفي عنوان مشروع Supabase ومفتاح anon/publishable في supabase-config.js');
  }
  if (!window.supabase?.createClient) throw new Error('مكتبة Supabase JS غير محمّلة');
  return window.supabase.createClient(url, anonKey, {
    auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true }
  });
};
