// src/client/home.ts
// Fetch and display meal requests on the homepage
import { formatMealRequestWindow } from "../utils/date.js";

export interface PublicMealRequest {
  id: string;
  vendor: string;
  food: string;
  pickupWindowText: string;
  windowStart: string | null;
  windowEnd: string | null;
  status: 'open';
  createdAt: string;
  expiresAt: string;
}

export interface PublicRequestListResponse {
  requests: PublicMealRequest[];
}

export const WEB_ORDERING_UNAVAILABLE_MESSAGE =
  "Ordering from the web is temporarily unavailable.";

export const ALERTS_UNAVAILABLE_MESSAGE =
  "Meal request alerts are temporarily unavailable.";

export const VOLUNTEER_AVAILABILITY_PAUSED_MESSAGE =
  "Volunteer availability is temporarily paused.";

export function activeSubscriberCountMessage(
  count: unknown,
  publicActionsPaused: boolean
): string {
  if (publicActionsPaused) return VOLUNTEER_AVAILABILITY_PAUSED_MESSAGE;
  return typeof count === "number" && count > 0
    ? `${count} volunteer${count === 1 ? "" : "s"} ready to fulfill requests`
    : "Volunteers are signing up—check back soon!";
}

export function applyActiveSubscriberCount(
  root: Document,
  count: unknown,
  publicActionsPaused: boolean
): void {
  const message = activeSubscriberCountMessage(count, publicActionsPaused);
  const activeCount = root.getElementById("active-count");
  const heroCount = root.getElementById("active-subscriber-hero");
  if (activeCount) activeCount.textContent = message;
  if (heroCount) heroCount.textContent = message;
}

/**
 * Asks the server whether public actions are paused. Any failure is treated as
 * paused: no address should be accepted while confirmation and unsubscribe are
 * incomplete, so the safe direction is to withhold the signup control.
 */
export async function fetchPublicActionsPaused(): Promise<boolean> {
  try {
    const response = await fetch('/api/public-actions');
    if (!response.ok) return true;
    const body = await response.json();
    return body?.paused !== false;
  } catch {
    return true;
  }
}

/**
 * Replaces the alerts signup control with a neutral unavailable message.
 * Browsing is untouched — only the subscription entry point is withheld.
 */
export function applySubscriptionPause(root: Document): void {
  const subscribeBtn = root.getElementById('subscribe-cta-btn');
  const subscribePanel = root.getElementById('subscribe-panel');
  const unavailable = root.getElementById('alerts-unavailable');

  if (subscribeBtn) subscribeBtn.hidden = true;
  if (subscribePanel) {
    subscribePanel.hidden = true;
    subscribePanel.style.display = 'none';
  }
  if (unavailable) {
    unavailable.textContent = ALERTS_UNAVAILABLE_MESSAGE;
    unavailable.hidden = false;
  }
}

// Utility function to escape HTML and prevent XSS
function clientEscapeHtml(text: string): string {
  const div = document.createElement('div');
  div.textContent = text;
  return div.innerHTML;
}

export function requestsFromResponse(
  response: PublicRequestListResponse
): PublicMealRequest[] {
  return response.requests;
}

export function publicRequestWindowText(request: PublicMealRequest): string {
  return formatMealRequestWindow(
    request.windowStart ?? undefined,
    request.windowEnd ?? undefined,
    request.pickupWindowText
  );
}

export function renderPublicRequestCard(request: PublicMealRequest): string {
  return `
            <div class="request-card" data-request-id="${clientEscapeHtml(request.id)}">
            <div class="card-window">${clientEscapeHtml(publicRequestWindowText(request))}</div>
            <div class="card-pickup">${clientEscapeHtml(request.food)} · ${clientEscapeHtml(request.vendor)}</div>
            <button class="card-action-btn" type="button" disabled aria-disabled="true">${WEB_ORDERING_UNAVAILABLE_MESSAGE}</button>
          </div>
        `;
}

export function renderPublicRequestDetail(request: PublicMealRequest): string {
  return `
      <div class="modal-body">
        <div class="detail-group">
          <label>Pickup Window</label>
          <p class="detail-window">${clientEscapeHtml(publicRequestWindowText(request))}</p>
        </div>
        <div class="detail-group">
          <label>What They Want</label>
          <p class="detail-food">${clientEscapeHtml(request.food)}</p>
        </div>
        <div class="detail-group">
          <label>Where From</label>
          <p>${clientEscapeHtml(request.vendor)}</p>
        </div>
      </div>
  `;
}

export function renderPublicRequestModal(request: PublicMealRequest): string {
  return `
    <div class="modal-content">
      <button class="modal-close" aria-label="Close">&times;</button>
      <div class="modal-header">
        <h2>Request Details</h2>
      </div>
      ${renderPublicRequestDetail(request)}
      <div class="modal-actions">
        <button class="btn btn-primary modal-order-btn" type="button" disabled aria-disabled="true">${WEB_ORDERING_UNAVAILABLE_MESSAGE}</button>
        <button class="btn btn-secondary modal-cancel-btn">Maybe Later</button>
      </div>
    </div>
  `;
}

function clientShowRequestDetail(request: PublicMealRequest): void {
  const modal = document.createElement('div');
  modal.className = 'modal-overlay';
  modal.innerHTML = renderPublicRequestModal(request);
  document.body.appendChild(modal);
  const closeModal = () => {
    modal.remove();
  };
  modal.querySelector('.modal-close')?.addEventListener('click', closeModal);
  modal.querySelector('.modal-cancel-btn')?.addEventListener('click', closeModal);
  modal.addEventListener('click', (e) => {
    if (e.target === modal) closeModal();
  });
  setTimeout(() => {
    (modal.querySelector('.modal-close') as HTMLElement)?.focus();
  }, 100);
}

document.addEventListener('DOMContentLoaded', async () => {
  const subscribeBtn = document.getElementById('subscribe-cta-btn');
  const subscribePanel = document.getElementById('subscribe-panel');
  const subscribeForm = document.getElementById('subscribe-form') as HTMLFormElement | null;
  const subscribeEmail = document.getElementById('subscribe-email') as HTMLInputElement | null;
  const subscribeCancel = document.getElementById('subscribe-cancel');
  const subscribeMessage = document.getElementById('subscribe-message');

  // Fire-and-forget so the pause probe never delays browsing. The signup
  // control is withheld as soon as the answer arrives; the server refuses
  // POST /api/subscribe throughout, so no address can be accepted meanwhile.
  let publicActionsPaused = false;
  void fetchPublicActionsPaused().then((paused) => {
    publicActionsPaused = paused;
    if (paused) {
      applySubscriptionPause(document);
      applyActiveSubscriberCount(document, undefined, true);
    }
  });

  if (subscribeBtn && subscribePanel && subscribeForm && subscribeEmail && subscribeCancel && subscribeMessage) {
    subscribeBtn.addEventListener('click', () => {
      subscribePanel.style.display = 'block';
      subscribeEmail.focus();
      subscribeMessage.textContent = '';
    });
    subscribeCancel.addEventListener('click', () => {
      subscribePanel.style.display = 'none';
      subscribeForm.reset();
      subscribeMessage.textContent = '';
    });
    subscribeForm.addEventListener('submit', async (e) => {
      e.preventDefault();
      subscribeMessage.textContent = '';
      const email = subscribeEmail.value.trim();
      if (!email) {
        subscribeMessage.textContent = 'Please enter your NYU email.';
        return;
      }
      subscribeForm.querySelector('.subscribe-submit')?.setAttribute('disabled', 'true');
      subscribeMessage.textContent = 'Subscribing...';
      try {
        const res = await fetch('/api/subscribe', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ email })
        });
        const data = await res.json();
        if (res.ok) {
          subscribeMessage.textContent = 'Check your email to confirm your subscription!';
          subscribeForm.reset();
          setTimeout(() => {
            subscribePanel.style.display = 'none';
            subscribeMessage.textContent = '';
          }, 3000);
        } else {
          subscribeMessage.textContent = data?.error || 'Could not subscribe. Please try again.';
        }
      } catch (err) {
        subscribeMessage.textContent = 'Network error. Please try again.';
      } finally {
        subscribeForm.querySelector('.subscribe-submit')?.removeAttribute('disabled');
      }
    });
  }

  const requestsList = document.getElementById('requests-list');
  const activeCountEl = document.getElementById('active-count');
  const totalSharedEl = document.getElementById('total-shared');

  const heroCountEl = document.getElementById('active-subscriber-hero');
  async function updateActiveSubscriberCount() {
    try {
      const resp = await fetch('/api/active-subscriber-count');
      if (resp.ok) {
        const data = await resp.json();
        applyActiveSubscriberCount(document, data.count, publicActionsPaused);
      } else {
        if (activeCountEl) activeCountEl.textContent = '';
        if (heroCountEl) heroCountEl.textContent = '';
      }
    } catch {
      if (activeCountEl) activeCountEl.textContent = '';
      if (heroCountEl) heroCountEl.textContent = '';
    }
  }
  updateActiveSubscriberCount();


  try {
    const statsResponse = await fetch('/api/stats');
    if (statsResponse.ok) {
      const stats = await statsResponse.json();
      if (totalSharedEl) {
        totalSharedEl.textContent = `${stats.totalShared} total meals shared`;
      }
    }
    
    const requestsResponse = await fetch('/api/requests');
    if (requestsResponse.ok) {
      const response: PublicRequestListResponse = await requestsResponse.json();
      const requests = requestsFromResponse(response);
      
      if (activeCountEl) {
        const activeCount = requests.length;
        activeCountEl.textContent = activeCount === 1 
          ? '1 active request right now' 
          : `${activeCount} active requests right now`;
      }
      
      if (!requestsList) return;
      if (requests.length === 0) {
        requestsList.innerHTML = '<p class="loading">No active requests right now.</p>';
      } else {
        requestsList.innerHTML = requests.map(renderPublicRequestCard).join('');

        document.querySelectorAll('.request-card').forEach(card => {
          card.addEventListener('click', (e) => {
            if ((e.target as HTMLElement).classList.contains('card-action-btn')) return;
            
            const requestId = (card as HTMLElement).dataset.requestId;
            const request = requests.find(r => r.id === requestId);
            if (request) {
              clientShowRequestDetail(request);
            }
          });
        });
      }
    } else if (requestsList) {
      requestsList.innerHTML = '<p class="loading">Unable to load requests.</p>';
    }
  } catch (error) {
    console.error('Error fetching requests:', error);
    if (requestsList) requestsList.innerHTML = '<p class="loading">Error loading requests.</p>';
  }
});
