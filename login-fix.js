(function () {
  const SUPABASE_URL = 'https://iiuqxxrrruvwvfehrzic.supabase.co';
  const SUPABASE_KEY = 'sb_publishable_b8r2Nb1BWv4cndNyEJ75dA_o40__ZPQ';
  let client = null;
  let signingIn = false;

  function getClient() {
    if (!client) {
      if (!window.supabase || !window.supabase.createClient) {
        throw new Error('Supabase failed to load. Please refresh the page and try again.');
      }
      client = window.supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
    }
    return client;
  }

  function showError(messageText) {
    const message = document.getElementById('authMessage') || document.querySelector('.auth-message');
    if (message) {
      message.className = 'auth-message show error';
      message.textContent = messageText;
    } else {
      alert(messageText);
    }
  }

  async function signIn() {
    if (signingIn) return;

    const email = document.getElementById('loginEmail');
    const password = document.getElementById('loginPassword');
    const button = document.getElementById('loginButton');

    if (!email || !password) {
      showError('Login fields could not be found.');
      return;
    }

    const emailValue = email.value.trim();
    const passwordValue = password.value;

    if (!emailValue || !passwordValue) {
      showError('Please enter your email and password.');
      return;
    }

    signingIn = true;

    if (button) {
      button.disabled = true;
      button.textContent = 'Signing in...';
    }

    try {
      const result = await getClient().auth.signInWithPassword({
        email: emailValue,
        password: passwordValue
      });

      if (result.error) throw result.error;
      if (!result.data || !result.data.session || !result.data.user) {
        throw new Error('Sign-in succeeded, but no active session was returned.');
      }

      // Do NOT call the dashboard handler here. The original page has its own
      // auth startup sequence. A clean reload lets that sequence read the newly
      // persisted Supabase session without racing the sign-in request.
      window.location.reload();
    } catch (error) {
      console.error('Sign-in error:', error);
      signingIn = false;
      if (button) {
        button.disabled = false;
        button.textContent = 'Sign In';
      }
      showError(error && error.message ? error.message : 'Unable to sign in. Please try again.');
    }
  }

  // Replace the inline login handler with this single handler.
  window.login = signIn;

  // Capture only the actual Sign In button. Inputs remain completely untouched,
  // so typing/clicking into the fields cannot be intercepted by this script.
  document.addEventListener('click', function (event) {
    const button = event.target.closest ? event.target.closest('#loginButton') : null;
    if (!button) return;
    event.preventDefault();
    event.stopImmediatePropagation();
    signIn();
  }, true);

  document.addEventListener('keydown', function (event) {
    if (event.key !== 'Enter') return;
    const active = document.activeElement;
    if (!active) return;
    if (active.id !== 'loginEmail' && active.id !== 'loginPassword') return;
    event.preventDefault();
    event.stopImmediatePropagation();
    signIn();
  }, true);
})();
