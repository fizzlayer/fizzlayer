// Upgrade offers on the plain-JS app pages, settings.html and app.html. The Gleam app has its own
// in app/src/gateway.gleam. Prices and limits are the pricing page's (app/src/site/pricing.gleam).
(() => {
  const plans = {
    tinkerer: { name: 'Tinkerer', price: '$10 a month', reason: '10 connected devices, 10 MCP servers, 100 Fizz credits and 20 phone calls a month.' },
    pro: { name: 'Pro', price: '$25 a month', reason: '50 connected devices, 25 MCP servers, 1,000 Fizz credits and 100 phone calls a month.' },
  };
  // Enterprise is arranged with us, so Pro and Enterprise get no offer.
  const next = { hobbyist: ['tinkerer', 'pro'], tinkerer: ['pro'] };

  function offers(planId) {
    return (next[planId] || []).map((id) => ({ id, ...plans[id] }));
  }

  // Fill `box` with one row per offer, or hide it when there is none. `returnTo` is the checkout
  // return page: 'settings' or 'app'.
  function render(box, planId, returnTo) {
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
      const link = document.createElement('a');
      link.className = 'secondary';
      link.href = `/app/checkout?plan=${offer.id}&return=${returnTo}`;
      link.textContent = `Upgrade to ${offer.name}`;
      row.append(text, link);
      return row;
    });
    box.replaceChildren(...rows);
    box.hidden = rows.length === 0;
  }

  window.fizzUpsell = { offers, render };
})();
