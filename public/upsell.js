// Upgrade offers on the plain-JS app pages, settings.html and app.html. The Gleam app has its own
// in app/src/gateway.gleam. Prices and limits are the pricing page's (app/src/site/pricing.gleam).
(() => {
  const plans = {
    tinkerer: { name: 'Tinkerer', price: '$10 a month', reason: '10 connected devices, 10 MCP servers, 100 Fizz credits and 20 phone calls a month.' },
    pro: { name: 'Pro', price: '$25 a month', reason: '50 connected devices, 25 MCP servers, 1,000 Fizz credits and 100 phone calls a month.' },
  };
  // Hobbyist buys a plan on /app/checkout. Tinkerer is paid, so it already has a subscription;
  // checkout refuses a second one (already_subscribed), so it switches in the Stripe billing
  // portal. Enterprise is arranged with us, so Pro and Enterprise get no offer.
  const next = {
    hobbyist: [{ id: 'tinkerer', action: 'checkout' }, { id: 'pro', action: 'checkout' }],
    tinkerer: [{ id: 'pro', action: 'portal' }],
  };

  function offers(planId) {
    return (next[planId] || []).map((offer) => ({ ...offer, ...plans[offer.id] }));
  }

  // aria-disabled rather than disabled, so the button keeps focus while the request runs.
  async function openPortal(button, message, returnTo) {
    if (button.getAttribute('aria-disabled') === 'true') return;
    button.setAttribute('aria-disabled', 'true');
    message.textContent = '';
    try {
      const response = await fetch('/api/billing', {
        method: 'POST', credentials: 'same-origin', headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ action: 'portal', return_to: returnTo }),
      });
      const data = await response.json().catch(() => ({}));
      if (!response.ok || typeof data.url !== 'string' || !data.url.startsWith('https://')) {
        throw new Error(data.error?.message || 'Billing could not be opened. Try again.');
      }
      location.href = data.url;
    } catch (error) {
      message.textContent = error instanceof TypeError ? 'Billing could not be opened. Try again.' : error.message;
    } finally {
      // Not left disabled: going Back from Stripe can restore this page as it was.
      button.removeAttribute('aria-disabled');
    }
  }

  // Fill `box` with one row per offer, or hide it when there is none. `returnTo` is where checkout
  // or the portal comes back to: 'settings' or 'app'.
  function render(box, planId, returnTo) {
    const message = document.createElement('p');
    message.className = 'plan-upsell-message';
    message.setAttribute('role', 'status');
    const rows = offers(planId).map((offer) => {
      const row = document.createElement('div');
      row.className = 'plan-upsell-offer';
      const text = document.createElement('p');
      const name = document.createElement('strong');
      name.textContent = offer.name;
      const price = document.createElement('span');
      price.className = 'plan-upsell-price';
      price.textContent = offer.price;
      const reason = document.createElement('span');
      reason.className = 'plan-upsell-reason';
      reason.textContent = offer.reason;
      text.append(name, price, reason);
      let action;
      if (offer.action === 'portal') {
        action = document.createElement('button');
        action.type = 'button';
        action.textContent = `Switch to ${offer.name}`;
        action.addEventListener('click', () => openPortal(action, message, returnTo));
      } else {
        action = document.createElement('a');
        action.href = `/app/checkout?plan=${offer.id}&return=${returnTo}`;
        action.textContent = `Upgrade to ${offer.name}`;
      }
      action.className = 'secondary';
      row.append(text, action);
      return row;
    });
    box.replaceChildren(...rows, ...(rows.length ? [message] : []));
    box.hidden = rows.length === 0;
  }

  window.fizzUpsell = { offers, render };
})();
