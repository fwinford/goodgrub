// src/client/fulfill.ts

import { formatMealRequestWindow } from "../utils/date.js";

// Legacy web fulfillment remains disabled; claim-authorized placement is
// handled by the iOS flow.

export const WEB_ORDERING_UNAVAILABLE_MESSAGE =
  "Ordering from the web is temporarily unavailable.";

export function isLegacyWebOrderingAvailable(): boolean {
  return false;
}

export function showLegacyWebOrderingUnavailable(root: Document): void {
  const form = root.getElementById('fulfill-form') as HTMLFormElement | null;
  const submitBtn = root.getElementById('submit-btn') as HTMLButtonElement | null;
  const errorMsg = root.getElementById('error-message') as HTMLDivElement | null;
  const summary = root.getElementById('request-summary') as HTMLElement | null;

  if (form) form.hidden = true;
  if (submitBtn) submitBtn.disabled = true;
  if (summary) summary.textContent = WEB_ORDERING_UNAVAILABLE_MESSAGE;
  if (errorMsg) {
    errorMsg.textContent = WEB_ORDERING_UNAVAILABLE_MESSAGE;
    errorMsg.style.display = 'block';
  }
}

async function fetchRequest(id: string) {
  const resp = await fetch(`/api/request/${id}`);
  if (!resp.ok) throw new Error('Request not found');
  return resp.json();
}

const escapeHtmlSafe = (text: string) => {
  const div = document.createElement('div');
  div.textContent = text;
  return div.innerHTML;
};

document.addEventListener('DOMContentLoaded', () => {
  const form = document.getElementById('fulfill-form') as HTMLFormElement | null;
  const submitBtn = document.getElementById('submit-btn') as HTMLButtonElement | null;
  const errorMsg = document.getElementById('error-message') as HTMLDivElement | null;
  const successMsg = document.getElementById('success-message') as HTMLDivElement | null;
  const detailsVendor = document.getElementById('details-vendor') as HTMLElement | null;
  const detailsFood = document.getElementById('details-food') as HTMLElement | null;
  const detailsWindow = document.getElementById('details-window') as HTMLElement | null;
  const orderNumberVal = document.getElementById('order-number-val') as HTMLElement | null;
  const orderNumberDisplay = document.getElementById('order-number-display') as HTMLElement | null;

  if (!form || !submitBtn || !errorMsg || !successMsg) return;

  if (!isLegacyWebOrderingAvailable()) {
    showLegacyWebOrderingUnavailable(document);
    return;
  }

  const pathParts = window.location.pathname.split('/').filter(Boolean);
  const requestId = pathParts.length >= 2 ? pathParts[1] : null;

  if (!requestId) {
    errorMsg.textContent = 'Invalid request ID in URL.';
    errorMsg.style.display = 'block';
    submitBtn.disabled = true;
    return;
  }

  (async () => {
    try {
      const req = await fetchRequest(requestId);
        if (detailsVendor) detailsVendor.textContent = req.vendor;
        if (detailsFood) detailsFood.textContent = req.food || '';
        if (detailsWindow) {
          // The backend derives `pickupWindowText` from the timing it actually
          // granted, so it is rendered as-is rather than re-described here. A
          // locally worded ASAP sentence was a second definition of the
          // request lifetime, and it outlived the lifetime it named.
          if (req.isAsap) {
            detailsWindow.textContent = req.pickupWindowText || 'Time window not specified';
          } else if (req.windowStart || req.windowEnd) {
              detailsWindow.textContent = formatMealRequestWindow(req.windowStart, req.windowEnd, req.pickupWindowText);
          } else {
            detailsWindow.textContent = req.pickupWindowText || 'Time window not specified';
          }
        }

        const elFood = document.getElementById('summary-food') as HTMLElement | null;
        const elVendor = document.getElementById('summary-vendor') as HTMLElement | null;
        const elFoodDetails = document.getElementById('summary-food-details') as HTMLElement | null;
        const elWindow = document.getElementById('summary-window') as HTMLElement | null;

        if (elFood) elFood.textContent = req.food || 'Unknown item';
        if (elVendor) elVendor.textContent = req.vendor ? `at ${req.vendor}` : '';
        if (elFoodDetails) elFoodDetails.textContent = req.details || req.foodDetails || '';
        if (elWindow) elWindow.textContent = req.isAsap
          ? (req.pickupWindowText || 'Time window not specified')
          : formatMealRequestWindow(req.windowStart, req.windowEnd, req.pickupWindowText);
    } catch (err) {
      errorMsg.textContent = 'Unable to load request details.';
      errorMsg.style.display = 'block';
      submitBtn.disabled = true;
    }
  })();

  function showThankYouGifModal(src: string | null) {
    if (!src) return;
    
    const overlay = document.createElement('div');
    overlay.className = 'modal-overlay';
    overlay.style.display = 'flex';
    overlay.style.position = 'fixed';
    overlay.style.top = '0';
    overlay.style.left = '0';
    overlay.style.right = '0';
    overlay.style.bottom = '0';
    overlay.style.backgroundColor = 'rgba(45, 45, 45, 0.6)';
    overlay.style.backdropFilter = 'blur(4px)';
    overlay.style.alignItems = 'center';
    overlay.style.justifyContent = 'center';
    overlay.style.zIndex = '1000';

    const content = document.createElement('div');
    content.className = 'modal-content';
    content.style.maxWidth = '680px';
    content.style.textAlign = 'center';
    content.style.background = 'white';
    content.style.borderRadius = '20px';
    content.style.position = 'relative';
    content.style.padding = '2rem 1.5rem';

    const closeBtn = document.createElement('button');
    closeBtn.className = 'modal-close';
    closeBtn.setAttribute('aria-label', 'Close thank you popup');
    closeBtn.textContent = '×';
    closeBtn.style.position = 'absolute';
    closeBtn.style.top = '1.25rem';
    closeBtn.style.right = '1.25rem';
    closeBtn.style.background = 'none';
    closeBtn.style.border = 'none';
    closeBtn.style.fontSize = '2rem';
    closeBtn.style.cursor = 'pointer';
    closeBtn.addEventListener('click', () => { 
      if (document.body.contains(overlay)) {
        document.body.removeChild(overlay); 
      }
    });

    const heading = document.createElement('h2');
    heading.textContent = 'Thank you for sharing!';
    heading.style.fontSize = '1.75rem';
    heading.style.fontWeight = '700';
    heading.style.color = '#7e6ab7';
    heading.style.marginBottom = '0.5rem';

    const message = document.createElement('p');
    message.textContent = 'Your kindness makes a difference in our community.';
    message.style.fontSize = '1rem';
    message.style.color = '#6b6b6b';
    message.style.marginBottom = '1.5rem';

    const img = document.createElement('img');
    img.src = src;
    img.alt = 'Thank you';
    img.style.maxWidth = '100%';
    img.style.borderRadius = '12px';
    img.style.display = 'block';
    img.style.margin = '0 auto';
    
    img.onerror = () => {
      console.error('Failed to load thank you GIF from:', src);
      if (document.body.contains(overlay)) {
        document.body.removeChild(overlay);
      }
    };

    content.appendChild(closeBtn);
    content.appendChild(heading);
    content.appendChild(message);
    content.appendChild(img);
    overlay.appendChild(content);
    document.body.appendChild(overlay);

    setTimeout(() => {
      if (document.body.contains(overlay)) document.body.removeChild(overlay);
    }, 3500);
  }

  async function tryShowThankYou() {
    return new Promise<void>((resolve) => {
      const probe = new Image();
      probe.onload = () => { showThankYouGifModal('/images/thankyou.gif'); resolve(); };
      probe.onerror = () => resolve();
      probe.src = '/images/thankyou.gif';
    });
  }

  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    errorMsg.style.display = 'none';
    successMsg.style.display = 'none';
    submitBtn.disabled = true;
    submitBtn.textContent = 'Submitting...';

  const formData = new FormData(form);
  const orderNumber = (formData.get('orderNumber') || '').toString().trim();
  const eta = (formData.get('eta') || '').toString().trim();
  const fulfillerEmail = (formData.get('fulfillerEmail') || '').toString().trim();
  const contactMessage = (formData.get('contactMessage') || '').toString().trim();

    if (!orderNumber) {
      errorMsg.textContent = 'Please enter the Grubhub order number.';
      errorMsg.style.display = 'block';
      submitBtn.disabled = false;
      submitBtn.textContent = 'Place Order';
      return;
    }

    if (!fulfillerEmail) {
      errorMsg.textContent = 'Please provide your email so the requester can contact you.';
      errorMsg.style.display = 'block';
      submitBtn.disabled = false;
      submitBtn.textContent = 'Place Order';
      return;
    }

    // Basic sanity check to avoid obviously bogus input. Accept short numeric or
    // alphanumeric order numbers (some providers use short ids like "26").
    if (!/^[A-Za-z0-9_-]{1,50}$/.test(orderNumber)) {
      errorMsg.textContent = 'That doesn\'t look like a valid Grubhub order number. Please check and try again.';
      errorMsg.style.display = 'block';
      submitBtn.disabled = false;
      submitBtn.textContent = 'Place Order';
      return;
    }
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(fulfillerEmail)) {
      errorMsg.textContent = 'Please enter a valid email address.';
      errorMsg.style.display = 'block';
      submitBtn.disabled = false;
      submitBtn.textContent = 'Place Order';
      return;
    }

    try {
  const body: { orderNumber: string; eta?: string; fulfillerEmail?: string; contactMessage?: string } = { orderNumber };
  if (eta) body.eta = eta;
  if (fulfillerEmail) body.fulfillerEmail = fulfillerEmail;
  if (contactMessage) body.contactMessage = contactMessage;

      const resp = await fetch(`/api/request/${requestId}/fulfill`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
      });

      const result = await resp.json();
      if (!resp.ok) throw new Error(result.error || 'Failed to fulfill request');

      if (orderNumberVal) orderNumberVal.textContent = escapeHtmlSafe(orderNumber);
      if (orderNumberDisplay) orderNumberDisplay.style.display = 'block';

      successMsg.textContent = 'Order placed — requester has been notified.';
      successMsg.style.display = 'block';
      form.reset();

      tryShowThankYou();

      setTimeout(() => { window.location.href = '/'; }, 3000);
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      errorMsg.textContent = `Error: ${msg}`;
      errorMsg.style.display = 'block';
    } finally {
      submitBtn.disabled = false;
      submitBtn.textContent = 'Place Order';
    }
  });
});
