(function(){
  const URL='https://iiuqxxrrruvwvfehrzic.supabase.co';
  const KEY='sb_publishable_b8r2Nb1BWv4cndNyEJ75dA_o40__ZPQ';
  const STORAGE='goalie-analytics-auth';

  function showError(text){
    const el=document.getElementById('authMessage');
    if(el){el.textContent=text;el.className='auth-message show error';}
  }

  async function boot(){
    if(!window.supabase || !window.supabase.createClient) return;
    try{
      const client=window.supabase.createClient(URL,KEY,{auth:{persistSession:true,autoRefreshToken:true,detectSessionInUrl:true,storageKey:STORAGE}});
      window.supabaseClient=client;
      const button=document.getElementById('loginButton');
      if(!button) return;
      button.onclick=async function(e){
        e.preventDefault();
        const email=(document.getElementById('loginEmail')?.value||'').trim();
        const password=document.getElementById('loginPassword')?.value||'';
        if(!email||!password){showError('Please enter your email and password.');return;}
        button.disabled=true;button.textContent='Signing in...';
        try{
          const {data,error}=await client.auth.signInWithPassword({email,password});
          if(error) throw error;
          if(!data?.session) throw new Error('Login succeeded but no session was returned.');
          await client.auth.setSession({access_token:data.session.access_token,refresh_token:data.session.refresh_token});
          window.location.replace('/dashboard.html?auth=1');
        }catch(err){
          showError(err?.message||'Unable to sign in.');
          button.disabled=false;button.textContent='Sign In';
        }
      };
    }catch(err){showError(err?.message||'Unable to initialize sign in.');}
  }
  if(document.readyState==='loading') document.addEventListener('DOMContentLoaded',boot); else boot();
  window.addEventListener('load',boot);
})();
