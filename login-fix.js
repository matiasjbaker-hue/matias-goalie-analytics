(function () {
  const SUPABASE_URL = 'https://iiuqxxrrruvwvfehrzic.supabase.co';
  const SUPABASE_KEY = 'sb_publishable_b8r2Nb1BWv4cndNyEJ75dA_o40__ZPQ';
  let client = null;
  let handlingSession = false;

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

  async function showAuthenticatedApp(user) {
    if (!user || handlingSession) return;
    handlingSession = true;
    try {
      if (typeof window.handleAuthenticatedUser === 'function') {
        await window.handleAuthenticatedUser(user);
      } else {
        window.location.reload();
      }
    } catch (error) {
      console.error('Authenticated app error:', error);
      showError(error && error.message ? error.message : 'Unable to load your dashboard.');
    } finally {
      handlingSession = false;
    }
  }

  async function signIn() {
    const email = document.getElementById('loginEmail') || document.querySelector('#authScreen input[type="email"]') || document.querySelector('input[type="email"]');
    const password = document.getElementById('loginPassword') || document.querySelector('#authScreen input[type="password"]') || document.querySelector('input[type="password"]');
    const button = document.getElementById('loginButton') || Array.from(document.querySelectorAll('button')).find(function (b) {
      return b.textContent.trim().toLowerCase() === 'sign in';
    });

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

    if (button) {
      button.disabled = true;
      button.textContent = 'Signing in...';
    }

    try {
      const authClient = getClient();
      const result = await authClient.auth.signInWithPassword({
        email: emailValue,
        password: passwordValue
      });

      if (result.error) throw result.error;
      if (!result.data || !result.data.session || !result.data.user) {
        throw new Error('Sign-in succeeded, but no active session was returned.');
      }

      await showAuthenticatedApp(result.data.user);
    } catch (error) {
      console.error('Sign-in error:', error);
      showError(error && error.message ? error.message : 'Unable to sign in. Please try again.');
    } finally {
      if (button) {
        button.disabled = false;
        button.textContent = 'Sign In';
      }
    }
  }

  window.login = signIn;

  // Keep the login screen and dashboard synchronized with the Supabase session.
  try {
    getClient().auth.onAuthStateChange(function (event, session) {
      if (session && session.user && (event === 'SIGNED_IN' || event === 'INITIAL_SESSION' || event === 'TOKEN_REFRESHED')) {
        setTimeout(function () {
          showAuthenticatedApp(session.user);
        }, 0);
      }
    });
  } catch (error) {
    console.error('Auth listener setup error:', error);
  }

  document.addEventListener('click', function (event) {
    const button = event.target.closest ? event.target.closest('button') : null;
    if (!button) return;
    if (button.id === 'loginButton' || button.textContent.trim().toLowerCase() === 'sign in') {
      event.preventDefault();
      event.stopPropagation();
      signIn();
    }
  }, true);

  document.addEventListener('keydown', function (event) {
    if (event.key !== 'Enter') return;
    const active = document.activeElement;
    if (active && (active.type === 'email' || active.type === 'password' || active.id === 'loginEmail' || active.id === 'loginPassword')) {
      event.preventDefault();
      signIn();
    }
  });
})();
