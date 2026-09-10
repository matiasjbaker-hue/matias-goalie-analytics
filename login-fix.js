(function () {
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
      if (!window.supabase || !window.supabase.createClient) {
        throw new Error('Supabase failed to load. Please refresh the page and try again.');
      }

      const client = window.supabase.createClient(
        'https://iiuqxxrrruvwvfehrzic.supabase.co',
        'sb_publishable_b8r2Nb1BWv4cndNyEJ75dA_o40__ZPQ'
      );

      const result = await client.auth.signInWithPassword({
        email: emailValue,
        password: passwordValue
      });

      if (result.error) throw result.error;
      if (!result.data || !result.data.session || !result.data.user) {
        throw new Error('Sign-in succeeded, but no active session was returned.');
      }

      if (typeof window.handleAuthenticatedUser === 'function') {
        await window.handleAuthenticatedUser(result.data.user);
      } else {
        window.location.reload();
      }
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
