(() => {
  const form = document.getElementById('pair-form');
  if (!form) return;
  const message = document.getElementById('pair-message');
  const code = document.getElementById('pair-code');
  const name = document.getElementById('pair-name');
  const submit = form.querySelector('button[type="submit"]');

  document.getElementById('install-cmd').textContent = `curl -fsSL ${location.origin}/install.sh | sh`;
  document.getElementById('pair-cmd').textContent = `FIZZ_API=${location.origin} fizz pair`;

  for (const button of document.querySelectorAll('[data-copy-command]')) {
    button.addEventListener('click', async () => {
      try {
        await navigator.clipboard.writeText(document.getElementById(button.dataset.copyCommand).textContent);
        button.textContent = 'Copied';
        setTimeout(() => { button.textContent = 'Copy'; }, 1500);
      } catch {
        message.textContent = 'Copy is unavailable. Select the command in the box and copy it manually.';
      }
    });
  }

  form.addEventListener('submit', async (event) => {
    event.preventDefault();
    if (submit.disabled) return;
    message.textContent = '';
    if (!code.value.trim()) {
      message.textContent = 'Enter the code shown in your device terminal by fizz pair.';
      code.focus();
      return;
    }
    submit.disabled = true;
    submit.textContent = 'Pairing…';
    try {
      const response = await fetch('/api/devices', {
        method: 'POST', credentials: 'same-origin',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ action: 'claim', code: code.value.trim(), name: name.value.trim() }),
      });
      const result = await response.json();
      if (!response.ok) throw new Error(result.error?.message || 'Could not pair this device. Please try again.');
      message.textContent = `Code accepted for "${result.device_name}". Return to the device terminal and approve the request, then run fizz run --every 60. Your device will appear in Sensors after approval.`;
      form.reset();
    } catch (error) {
      message.textContent = error instanceof TypeError ? 'Could not reach Fizzlayer. Check your connection and try again.' : error.message;
    } finally {
      submit.disabled = false;
      submit.textContent = 'Pair device';
    }
  });
})();
