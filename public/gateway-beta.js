const form = document.getElementById('beta-form');
const status = document.getElementById('beta-status');
if (form && status) {
  form.addEventListener('submit', async (event) => {
    event.preventDefault();
    const email = document.getElementById('beta-email');
    const company = document.getElementById('beta-company');
    const button = form.querySelector('button');
    status.classList.remove('error');
    if (!email.checkValidity()) {
      status.classList.add('error');
      status.textContent = 'Enter a valid email address.';
      email.focus();
      return;
    }
    if (!company.value.trim()) {
      status.classList.add('error');
      status.textContent = 'Enter your name or company.';
      company.focus();
      return;
    }
    button.disabled = true;
    status.textContent = 'Sending…';
    try {
      const response = await fetch('/api/contact', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({
          email: email.value.trim(),
          company: company.value.trim(),
          interest: 'Gateway private beta',
        }),
      });
      const result = await response.json().catch(() => ({}));
      if (!response.ok) throw new Error(result.error?.message || 'Something went wrong. Try again.');
      status.textContent = `Saved for ${email.value.trim().toLowerCase()}. This does not create a gateway or reserve a plan.`;
      form.reset();
    } catch (error) {
      status.classList.add('error');
      status.textContent = error instanceof TypeError ? 'Could not reach Fizzlayer. Check your connection and try again.' : error.message;
    } finally {
      button.disabled = false;
    }
  });
}
