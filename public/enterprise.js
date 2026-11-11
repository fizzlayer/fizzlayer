const business = document.getElementById('business-form');
const businessStatus = document.getElementById('business-status');
if (business && businessStatus) {
  business.addEventListener('submit', async (event) => {
    event.preventDefault();
    const email = document.getElementById('business-email');
    const company = document.getElementById('business-company');
    const button = business.querySelector('button');
    businessStatus.classList.remove('error');
    const invalid = !email.checkValidity() ? [email, 'Enter a valid work email.'] : !company.value.trim() ? [company, 'Enter your company name.'] : null;
    if (invalid) {
      businessStatus.classList.add('error');
      businessStatus.textContent = invalid[1];
      invalid[0].focus();
      return;
    }
    button.disabled = true;
    businessStatus.textContent = 'Sending…';
    try {
      const response = await fetch('/api/contact', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({
          email: email.value.trim(),
          company: company.value.trim(),
          interest: document.getElementById('business-interest').value.trim(),
        }),
      });
      const result = await response.json().catch(() => ({}));
      if (!response.ok) throw new Error(result.error?.message || 'Something went wrong. Try again.');
      businessStatus.textContent = `Thanks. We'll be in touch at ${email.value.trim().toLowerCase()}.`;
      business.reset();
    } catch (error) {
      businessStatus.classList.add('error');
      businessStatus.textContent = error instanceof TypeError ? 'Could not reach Fizzlayer. Check your connection and try again.' : error.message;
    } finally {
      button.disabled = false;
    }
  });
}
