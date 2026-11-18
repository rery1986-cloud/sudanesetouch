/* Lamsa Touch integration helpers; loaded after Supabase JS and supabase-config.js. */
(() => {
  'use strict';
  const ROLE_LABELS = { client: 'عميلة', provider: 'مقدمة خدمة', merchant: 'تاجرة / صاحبة بازار', admin: 'مديرة النظام', moderator: 'أدمن' };
  const MERCHANT_CATEGORIES = ['البخور', 'الكابيه', 'الشعاري', 'الإكسسوارات', 'الثياب', 'أخرى'];
  const countries = {
    'السعودية': ['الرياض','جدة','مكة','المدينة','الدمام','الخبر','أبها','الطائف'],
    'مصر': ['القاهرة','الإسكندرية','الجيزة','المنصورة','أسوان'],
    'الإمارات': ['دبي','أبوظبي','الشارقة','عجمان','العين'],
    'السودان': ['الخرطوم','أم درمان','بحري','بورتسودان','ود مدني','كسلا','الأبيض','عطبرة']
  };
  const db = () => {
    if (!window.lamsaSupabase) window.lamsaSupabase = window.createLamsaSupabaseClient();
    return window.lamsaSupabase;
  };
  const escapeHtml = value => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  async function register({ email, password, full_name, phone_private, role='client', country, city, district, specialty, store_name }) {
    if (!['client','provider','merchant'].includes(role)) throw new Error('نوع الحساب غير مسموح بالتسجيل العام');
    if (role === 'merchant' && !store_name?.trim()) throw new Error('اسم المتجر أو البازار مطلوب');
    const { data, error } = await db().auth.signUp({ email, password, options: { data: { full_name, phone_private, role, country, city, district, specialty, store_name } } });
    if (error) throw error; return data;
  }
  async function signIn(email, password) {
    const { data, error } = await db().auth.signInWithPassword({ email, password }); if (error) throw error;
    const { data: profile, error: profileError } = await db().from('profiles').select('*').eq('id', data.user.id).single();
    if (profileError) throw profileError;
    if (!profile.is_active) { await db().auth.signOut(); throw new Error('الحساب غير مفعل'); }
    return { ...data, profile };
  }
  async function signOut() { const { error } = await db().auth.signOut(); if (error) throw error; }
  async function updateOwnProfile(changes) {
    const allowed = ['full_name','email','phone_private','country','city','district','specialty','store_name'];
    const safe = Object.fromEntries(Object.entries(changes).filter(([key]) => allowed.includes(key)));
    const { data: { user }, error: authError } = await db().auth.getUser(); if (authError || !user) throw authError || new Error('سجلي الدخول');
    const { data, error } = await db().from('profiles').update(safe).eq('id', user.id).select().single(); if (error) throw error;
    if (safe.email && safe.email !== user.email) { const result = await db().auth.updateUser({ email: safe.email }); if (result.error) throw result.error; }
    return data;
  }
  async function changePassword(currentPassword, newPassword, confirmPassword) {
    if (newPassword !== confirmPassword) throw new Error('كلمتا المرور الجديدتان غير متطابقتين');
    if (newPassword.length < 8) throw new Error('كلمة المرور يجب ألا تقل عن 8 أحرف');
    const { data: { user }, error } = await db().auth.getUser(); if (error || !user) throw error || new Error('سجلي الدخول');
    const check = await db().auth.signInWithPassword({ email: user.email, password: currentPassword }); if (check.error) throw new Error('كلمة المرور الحالية غير صحيحة');
    const result = await db().auth.updateUser({ password: newPassword }); if (result.error) throw result.error; return true;
  }
  async function ownProfile() {
    const { data: { user }, error } = await db().auth.getUser(); if (error || !user) throw error || new Error('سجلي الدخول');
    const result = await db().from('profiles').select('*').eq('id', user.id).single(); if (result.error) throw result.error; return result.data;
  }
  async function saveMerchantAd(ad) {
    const profile = await ownProfile(); if (profile.role !== 'merchant' || !profile.is_active) throw new Error('هذه الوظيفة متاحة للتاجرات فقط');
    const row = { title: ad.title, description: ad.description || '', product_category: MERCHANT_CATEGORIES.includes(ad.product_category) ? ad.product_category : 'أخرى', image_url: ad.image_url || null, logo_url: ad.logo_url || null, owner_photo_url: ad.owner_photo_url || null, price: ad.price || null, currency: ad.currency || null, country: profile.country, city: profile.city, merchant_id: profile.id };
    let query = ad.id ? db().from('merchant_ads').update(row).eq('id', ad.id) : db().from('merchant_ads').insert(row);
    const result = await query.select().single(); if (result.error) throw result.error; return result.data;
  }
  async function setAdHidden(id, hidden) { const profile = await ownProfile(); if (profile.role !== 'merchant') throw new Error('للتاجرات فقط'); const r = await db().from('merchant_ads').update({ is_hidden: !!hidden }).eq('id', id).eq('merchant_id', profile.id); if (r.error) throw r.error; }
  async function deleteMerchantAd(id) { const profile = await ownProfile(); if (profile.role !== 'merchant') throw new Error('للتاجرات فقط'); const r = await db().from('merchant_ads').delete().eq('id', id).eq('merchant_id', profile.id); if (r.error) throw r.error; }
  async function myMerchantAds() { const p = await ownProfile(); if (p.role !== 'merchant') throw new Error('للتاجرات فقط'); const r = await db().from('merchant_ads').select('*').eq('merchant_id', p.id).order('created_at',{ascending:false}); if (r.error) throw r.error; return r.data; }
  async function visibleMerchantAds({ country, city }={}) { let q=db().from('merchant_ads').select('*, profiles:merchant_id(full_name,store_name,logo_url)').eq('is_hidden',false); if(country) q=q.eq('country',country); if(city) q=q.eq('city',city); const r=await q.order('created_at',{ascending:false}); if(r.error) throw r.error; return r.data; }
  async function createModeratorInvite(details) {
    const p = await ownProfile(); if (p.role !== 'admin' || !p.is_active) throw new Error('مديرة النظام فقط تستطيع دعوة الأدمنز');
    const { data, error } = await db().functions.invoke('admin-invitations', { body: details }); if (error) throw error; return data;
  }
  async function acceptModeratorInvite({ token, email, password, confirmPassword, phone_private }) {
    if(password !== confirmPassword) throw new Error('كلمتا المرور غير متطابقتين');
    if(password.length < 8) throw new Error('كلمة المرور يجب ألا تقل عن 8 أحرف');
    const { data, error } = await db().auth.signUp({ email, password }); if(error) throw error;
    if(!data.session) throw new Error('أكدي بريدك الإلكتروني ثم سجلي الدخول لقبول الدعوة');
    const accepted=await db().rpc('accept_admin_invitation',{raw_token:token,submitted_phone:phone_private||null}); if(accepted.error) throw accepted.error;
    return data;
  }
  function updateCityOptions(countrySelect, citySelect, selected='') {
    const list = countries[countrySelect?.value] || [];
    citySelect.replaceChildren(new Option('اختاري المدينة',''), ...list.map(city => new Option(city,city)));
    if(list.includes(selected)) citySelect.value=selected;
  }
  // Minimal Arabic HTML helpers intended for existing app modal/dashboard integration.
  function merchantFormHtml(profile={}) {
    return `<section dir="rtl"><h2>حساب تاجرة / صاحبة بازار</h2><label>اسم المتجر أو البازار<input name="store_name" required value="${escapeHtml(profile.store_name)}"></label><label>الدولة<select name="country" data-lamsa-country required>${Object.keys(countries).map(c=>`<option ${profile.country===c?'selected':''}>${escapeHtml(c)}</option>`).join('')}</select></label><label>المدينة<select name="city" data-lamsa-city required></select></label><label>المنتج<select name="product_category">${MERCHANT_CATEGORIES.map(c=>`<option>${escapeHtml(c)}</option>`).join('')}</select></label><label>صورة الإعلان<input type="file" name="image" accept="image/*"></label><label>الشعار<input type="file" name="logo" accept="image/*"></label><label>صورة صاحبة البازار<input type="file" name="owner_photo" accept="image/*"></label></section>`;
  }
  window.LamsaTouch = Object.freeze({ ROLE_LABELS, MERCHANT_CATEGORIES, countries, register, signIn, signOut, updateOwnProfile, changePassword, ownProfile, saveMerchantAd, setAdHidden, deleteMerchantAd, myMerchantAds, visibleMerchantAds, createModeratorInvite, acceptModeratorInvite, updateCityOptions, merchantFormHtml });
})();
