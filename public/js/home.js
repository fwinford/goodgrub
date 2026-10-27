// GENERATED FILE — do not edit.
// Built from src/client/*.ts by build-client.mjs (npm run build:client).
// Edit the TypeScript source; edits here are overwritten by the next build.

// src/utils/date.ts
var NYU_TIME_ZONE = "America/New_York";
function formatMealRequestWindow(start, end, fallback) {
  if (fallback && /\b(AM|PM)\b|Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec/i.test(fallback)) {
    return fallback;
  }
  if (!start && !end) return fallback || "Time window not specified";
  try {
    const s = start ? new Date(start) : null;
    const e = end ? new Date(end) : null;
    const optsDate = {
      month: "short",
      day: "numeric",
      timeZone: NYU_TIME_ZONE
    };
    const optsTime = { hour: "numeric", minute: "2-digit", hour12: true, timeZone: NYU_TIME_ZONE };
    if (s && e) {
      const sameDay = s.toLocaleDateString("en-US", { timeZone: NYU_TIME_ZONE }) === e.toLocaleDateString("en-US", { timeZone: NYU_TIME_ZONE });
      if (sameDay) {
        return `${s.toLocaleDateString("en-US", optsDate)}, ${s.toLocaleTimeString("en-US", optsTime)} \u2013 ${e.toLocaleTimeString("en-US", optsTime)}`;
      }
      return `${s.toLocaleString("en-US", { ...optsDate, ...optsTime })} \u2013 ${e.toLocaleString("en-US", { ...optsDate, ...optsTime })}`;
    }
    if (s) return `${s.toLocaleDateString("en-US", optsDate)}, ${s.toLocaleTimeString("en-US", optsTime)}`;
    if (e) return `Until ${e.toLocaleString("en-US", { ...optsDate, ...optsTime })}`;
    return fallback || "Time window not specified";
  } catch {
    if (start) return new Date(start).toLocaleString("en-US", { timeZone: NYU_TIME_ZONE });
    if (end) return new Date(end).toLocaleString("en-US", { timeZone: NYU_TIME_ZONE });
    return fallback || "Time window not specified";
  }
}

// src/client/home.ts
var WEB_ORDERING_UNAVAILABLE_MESSAGE = "Ordering from the web is temporarily unavailable.";
var ALERTS_UNAVAILABLE_MESSAGE = "Meal request alerts are temporarily unavailable.";
var VOLUNTEER_AVAILABILITY_PAUSED_MESSAGE = "Volunteer availability is temporarily paused.";
function activeSubscriberCountMessage(count, publicActionsPaused) {
  if (publicActionsPaused) return VOLUNTEER_AVAILABILITY_PAUSED_MESSAGE;
  return typeof count === "number" && count > 0 ? `${count} volunteer${count === 1 ? "" : "s"} ready to fulfill requests` : "Volunteers are signing up\u2014check back soon!";
}
function applyActiveSubscriberCount(root, count, publicActionsPaused) {
  const message = activeSubscriberCountMessage(count, publicActionsPaused);
  const activeCount = root.getElementById("active-count");
  const heroCount = root.getElementById("active-subscriber-hero");
  if (activeCount) activeCount.textContent = message;
  if (heroCount) heroCount.textContent = message;
}
async function fetchPublicActionsPaused() {
  try {
    const response = await fetch("/api/public-actions");
    if (!response.ok) return true;
    const body = await response.json();
    return body?.paused !== false;
  } catch {
    return true;
  }
}
function applySubscriptionPause(root) {
  const subscribeBtn = root.getElementById("subscribe-cta-btn");
  const subscribePanel = root.getElementById("subscribe-panel");
  const unavailable = root.getElementById("alerts-unavailable");
  if (subscribeBtn) subscribeBtn.hidden = true;
  if (subscribePanel) {
    subscribePanel.hidden = true;
    subscribePanel.style.display = "none";
  }
  if (unavailable) {
    unavailable.textContent = ALERTS_UNAVAILABLE_MESSAGE;
    unavailable.hidden = false;
  }
}
function clientEscapeHtml(text) {
  const div = document.createElement("div");
  div.textContent = text;
  return div.innerHTML;
}
function requestsFromResponse(response) {
  return response.requests;
}
function publicRequestWindowText(request) {
  return formatMealRequestWindow(
    request.windowStart ?? void 0,
    request.windowEnd ?? void 0,
    request.pickupWindowText
  );
}
function renderPublicRequestCard(request) {
  return `
            <div class="request-card" data-request-id="${clientEscapeHtml(request.id)}">
            <div class="card-window">${clientEscapeHtml(publicRequestWindowText(request))}</div>
            <div class="card-pickup">${clientEscapeHtml(request.food)} \xB7 ${clientEscapeHtml(request.vendor)}</div>
            <button class="card-action-btn" type="button" disabled aria-disabled="true">${WEB_ORDERING_UNAVAILABLE_MESSAGE}</button>
          </div>
        `;
}
function renderPublicRequestDetail(request) {
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
function renderPublicRequestModal(request) {
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
function clientShowRequestDetail(request) {
  const modal = document.createElement("div");
  modal.className = "modal-overlay";
  modal.innerHTML = renderPublicRequestModal(request);
  document.body.appendChild(modal);
  const closeModal = () => {
    modal.remove();
  };
  modal.querySelector(".modal-close")?.addEventListener("click", closeModal);
  modal.querySelector(".modal-cancel-btn")?.addEventListener("click", closeModal);
  modal.addEventListener("click", (e) => {
    if (e.target === modal) closeModal();
  });
  setTimeout(() => {
    modal.querySelector(".modal-close")?.focus();
  }, 100);
}
document.addEventListener("DOMContentLoaded", async () => {
  const subscribeBtn = document.getElementById("subscribe-cta-btn");
  const subscribePanel = document.getElementById("subscribe-panel");
  const subscribeForm = document.getElementById("subscribe-form");
  const subscribeEmail = document.getElementById("subscribe-email");
  const subscribeCancel = document.getElementById("subscribe-cancel");
  const subscribeMessage = document.getElementById("subscribe-message");
  let publicActionsPaused = false;
  void fetchPublicActionsPaused().then((paused) => {
    publicActionsPaused = paused;
    if (paused) {
      applySubscriptionPause(document);
      applyActiveSubscriberCount(document, void 0, true);
    }
  });
  if (subscribeBtn && subscribePanel && subscribeForm && subscribeEmail && subscribeCancel && subscribeMessage) {
    subscribeBtn.addEventListener("click", () => {
      subscribePanel.style.display = "block";
      subscribeEmail.focus();
      subscribeMessage.textContent = "";
    });
    subscribeCancel.addEventListener("click", () => {
      subscribePanel.style.display = "none";
      subscribeForm.reset();
      subscribeMessage.textContent = "";
    });
    subscribeForm.addEventListener("submit", async (e) => {
      e.preventDefault();
      subscribeMessage.textContent = "";
      const email = subscribeEmail.value.trim();
      if (!email) {
        subscribeMessage.textContent = "Please enter your NYU email.";
        return;
      }
      subscribeForm.querySelector(".subscribe-submit")?.setAttribute("disabled", "true");
      subscribeMessage.textContent = "Subscribing...";
      try {
        const res = await fetch("/api/subscribe", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ email })
        });
        const data = await res.json();
        if (res.ok) {
          subscribeMessage.textContent = "Check your email to confirm your subscription!";
          subscribeForm.reset();
          setTimeout(() => {
            subscribePanel.style.display = "none";
            subscribeMessage.textContent = "";
          }, 3e3);
        } else {
          subscribeMessage.textContent = data?.error || "Could not subscribe. Please try again.";
        }
      } catch (err) {
        subscribeMessage.textContent = "Network error. Please try again.";
      } finally {
        subscribeForm.querySelector(".subscribe-submit")?.removeAttribute("disabled");
      }
    });
  }
  const requestsList = document.getElementById("requests-list");
  const activeCountEl = document.getElementById("active-count");
  const totalSharedEl = document.getElementById("total-shared");
  const heroCountEl = document.getElementById("active-subscriber-hero");
  async function updateActiveSubscriberCount() {
    try {
      const resp = await fetch("/api/active-subscriber-count");
      if (resp.ok) {
        const data = await resp.json();
        applyActiveSubscriberCount(document, data.count, publicActionsPaused);
      } else {
        if (activeCountEl) activeCountEl.textContent = "";
        if (heroCountEl) heroCountEl.textContent = "";
      }
    } catch {
      if (activeCountEl) activeCountEl.textContent = "";
      if (heroCountEl) heroCountEl.textContent = "";
    }
  }
  updateActiveSubscriberCount();
  try {
    const statsResponse = await fetch("/api/stats");
    if (statsResponse.ok) {
      const stats = await statsResponse.json();
      if (totalSharedEl) {
        totalSharedEl.textContent = `${stats.totalShared} total meals shared`;
      }
    }
    const requestsResponse = await fetch("/api/requests");
    if (requestsResponse.ok) {
      const response = await requestsResponse.json();
      const requests = requestsFromResponse(response);
      if (activeCountEl) {
        const activeCount = requests.length;
        activeCountEl.textContent = activeCount === 1 ? "1 active request right now" : `${activeCount} active requests right now`;
      }
      if (!requestsList) return;
      if (requests.length === 0) {
        requestsList.innerHTML = '<p class="loading">No active requests right now.</p>';
      } else {
        requestsList.innerHTML = requests.map(renderPublicRequestCard).join("");
        document.querySelectorAll(".request-card").forEach((card) => {
          card.addEventListener("click", (e) => {
            if (e.target.classList.contains("card-action-btn")) return;
            const requestId = card.dataset.requestId;
            const request = requests.find((r) => r.id === requestId);
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
    console.error("Error fetching requests:", error);
    if (requestsList) requestsList.innerHTML = '<p class="loading">Error loading requests.</p>';
  }
});
export {
  ALERTS_UNAVAILABLE_MESSAGE,
  VOLUNTEER_AVAILABILITY_PAUSED_MESSAGE,
  WEB_ORDERING_UNAVAILABLE_MESSAGE,
  activeSubscriberCountMessage,
  applyActiveSubscriberCount,
  applySubscriptionPause,
  fetchPublicActionsPaused,
  publicRequestWindowText,
  renderPublicRequestCard,
  renderPublicRequestDetail,
  renderPublicRequestModal,
  requestsFromResponse
};
//# sourceMappingURL=home.js.map
