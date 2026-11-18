// Supabase Edge Function: create a single-use moderator invitation.
// Configure SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY as function secrets only.
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
const cors = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type', 'Access-Control-Allow-Methods': 'POST, OPTIONS' };
const json = (body: unknown, status=200) => new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });
Deno.serve(async (req: Request) => {
  if(req.method==='OPTIONS') return new Response('ok',{headers:cors});
  if(req.method!=='POST') return json({error:'Method not allowed'},405);
  const url=Deno.env.get('SUPABASE_URL'), key=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if(!url||!key) return json({error:'Server configuration missing'},500);
  const authHeader=req.headers.get('Authorization'); if(!authHeader) return json({error:'Unauthorized'},401);
  const admin=createClient(url,key,{auth:{persistSession:false}});
  const userClient=createClient(url,Deno.env.get('SUPABASE_ANON_KEY')||'',{global:{headers:{Authorization:authHeader}}});
  const {data:{user},error:userError}=await userClient.auth.getUser();
  if(userError||!user) return json({error:'Unauthorized'},401);
  const {data:profile,error:profileError}=await admin.from('profiles').select('role,is_active').eq('id',user.id).single();
  if(profileError||profile?.role!=='admin'||!profile.is_active||user.app_metadata?.platform_super_admin!==true) return json({error:'Only the platform administrator can invite admins'},403);
  const input=await req.json().catch(()=>null);
  if(!input||typeof input.email!=='string'||!input.email.includes('@')||typeof input.country!=='string'||typeof input.city!=='string') return json({error:'Email, country and city are required'},400);
  const bytes=crypto.getRandomValues(new Uint8Array(32)); const token=[...bytes].map(b=>b.toString(16).padStart(2,'0')).join('');
  const digest=await crypto.subtle.digest('SHA-256',new TextEncoder().encode(token));
  const tokenHash=[...new Uint8Array(digest)].map(b=>b.toString(16).padStart(2,'0')).join('');
  const {error:insertError}=await admin.from('admin_invitations').insert({email:input.email.trim().toLowerCase(),phone_private:input.phone_private||null,country:input.country,city:input.city,permissions:input.permissions||{},token_hash:tokenHash,invited_by:user.id});
  if(insertError) return json({error:'Could not create invitation'},500);
  const origin=req.headers.get('origin')||'';
  const inviteUrl=`${origin}/?invite=${encodeURIComponent(token)}`;
  return json({inviteUrl, whatsappUrl:`https://wa.me/?text=${encodeURIComponent(inviteUrl)}`, expiresInDays:7});
});
