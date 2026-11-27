// Stripe's embedded Checkout form. `@stripe/stripe-js/pure` adds the Stripe.js
// script from js.stripe.com only when a form mounts, so no other page loads it.
// Stripe allows one embedded form per page, so each mount destroys the last.
import { loadStripe } from "@stripe/stripe-js/pure/index.mjs";

let current = null;
// Bumped by every mount and unmount, so a mount that finishes late, after the
// page moved on, destroys its own form instead of showing it.
let generation = 0;

export function mount(frame_id, publishable_key, client_secret, mounted, paid) {
  unmount();
  const mine = generation;
  loadStripe(publishable_key)
    .then((stripe) => {
      if (!stripe) throw new Error("Stripe.js is not available");
      return stripe.createEmbeddedCheckoutPage({
        clientSecret: client_secret,
        onComplete: () => paid(),
      });
    })
    .then((checkout) => {
      const frame = document.getElementById(frame_id);
      if (mine !== generation || !frame) {
        checkout.destroy();
        return;
      }
      current = checkout;
      checkout.mount(frame);
      mounted(true);
    })
    .catch((error) => {
      if (mine !== generation) return;
      console.error("Stripe checkout failed to load", error);
      mounted(false);
    });
}

export function unmount() {
  generation += 1;
  if (!current) return;
  try {
    current.destroy();
  } catch {
    /* Already destroyed. */
  }
  current = null;
}
