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

// src/client/fulfill.ts
var WEB_ORDERING_UNAVAILABLE_MESSAGE = "Ordering from the web is temporarily unavailable.";
function isLegacyWebOrderingAvailable() {
  return false;
}
function showLegacyWebOrderingUnavailable(root) {
  const form = root.getElementById("fulfill-form");
  const submitBtn = root.getElementById("submit-btn");
  const errorMsg = root.getElementById("error-message");
  const summary = root.getElementById("request-summary");
  if (form) form.hidden = true;
  if (submitBtn) submitBtn.disabled = true;
  if (summary) summary.textContent = WEB_ORDERING_UNAVAILABLE_MESSAGE;
  if (errorMsg) {
    errorMsg.textContent = WEB_ORDERING_UNAVAILABLE_MESSAGE;
    errorMsg.style.display = "block";
  }
}
async function fetchRequest(id) {
  const resp = await fetch(`/api/request/${id}`);
  if (!resp.ok) throw new Error("Request not found");
  return resp.json();
}
var escapeHtmlSafe = (text) => {
  const div = document.createElement("div");
  div.textContent = text;
  return div.innerHTML;
};
document.addEventListener("DOMContentLoaded", () => {
  const form = document.getElementById("fulfill-form");
  const submitBtn = document.getElementById("submit-btn");
  const errorMsg = document.getElementById("error-message");
  const successMsg = document.getElementById("success-message");
  const detailsVendor = document.getElementById("details-vendor");
  const detailsFood = document.getElementById("details-food");
  const detailsWindow = document.getElementById("details-window");
  const orderNumberVal = document.getElementById("order-number-val");
  const orderNumberDisplay = document.getElementById("order-number-display");
  if (!form || !submitBtn || !errorMsg || !successMsg) return;
  if (!isLegacyWebOrderingAvailable()) {
    showLegacyWebOrderingUnavailable(document);
    return;
  }
  const pathParts = window.location.pathname.split("/").filter(Boolean);
  const requestId = pathParts.length >= 2 ? pathParts[1] : null;
  if (!requestId) {
    errorMsg.textContent = "Invalid request ID in URL.";
    errorMsg.style.display = "block";
    submitBtn.disabled = true;
    return;
  }
  (async () => {
    try {
      const req = await fetchRequest(requestId);
      if (detailsVendor) detailsVendor.textContent = req.vendor;
      if (detailsFood) detailsFood.textContent = req.food || "";
      if (detailsWindow) {
        if (req.isAsap) {
          detailsWindow.textContent = req.pickupWindowText || "Time window not specified";
        } else if (req.windowStart || req.windowEnd) {
          detailsWindow.textContent = formatMealRequestWindow(req.windowStart, req.windowEnd, req.pickupWindowText);
        } else {
          detailsWindow.textContent = req.pickupWindowText || "Time window not specified";
        }
      }
      const elFood = document.getElementById("summary-food");
      const elVendor = document.getElementById("summary-vendor");
      const elFoodDetails = document.getElementById("summary-food-details");
      const elWindow = document.getElementById("summary-window");
      if (elFood) elFood.textContent = req.food || "Unknown item";
      if (elVendor) elVendor.textContent = req.vendor ? `at ${req.vendor}` : "";
      if (elFoodDetails) elFoodDetails.textContent = req.details || req.foodDetails || "";
      if (elWindow) elWindow.textContent = req.isAsap ? req.pickupWindowText || "Time window not specified" : formatMealRequestWindow(req.windowStart, req.windowEnd, req.pickupWindowText);
    } catch (err) {
      errorMsg.textContent = "Unable to load request details.";
      errorMsg.style.display = "block";
      submitBtn.disabled = true;
    }
  })();
  function showThankYouGifModal(src) {
    if (!src) return;
    const overlay = document.createElement("div");
    overlay.className = "modal-overlay";
    overlay.style.display = "flex";
    overlay.style.position = "fixed";
    overlay.style.top = "0";
    overlay.style.left = "0";
    overlay.style.right = "0";
    overlay.style.bottom = "0";
    overlay.style.backgroundColor = "rgba(45, 45, 45, 0.6)";
    overlay.style.backdropFilter = "blur(4px)";
    overlay.style.alignItems = "center";
    overlay.style.justifyContent = "center";
    overlay.style.zIndex = "1000";
    const content = document.createElement("div");
    content.className = "modal-content";
    content.style.maxWidth = "680px";
    content.style.textAlign = "center";
    content.style.background = "white";
    content.style.borderRadius = "20px";
    content.style.position = "relative";
    content.style.padding = "2rem 1.5rem";
    const closeBtn = document.createElement("button");
    closeBtn.className = "modal-close";
    closeBtn.setAttribute("aria-label", "Close thank you popup");
    closeBtn.textContent = "\xD7";
    closeBtn.style.position = "absolute";
    closeBtn.style.top = "1.25rem";
    closeBtn.style.right = "1.25rem";
    closeBtn.style.background = "none";
    closeBtn.style.border = "none";
    closeBtn.style.fontSize = "2rem";
    closeBtn.style.cursor = "pointer";
    closeBtn.addEventListener("click", () => {
      if (document.body.contains(overlay)) {
        document.body.removeChild(overlay);
      }
    });
    const heading = document.createElement("h2");
    heading.textContent = "Thank you for sharing!";
    heading.style.fontSize = "1.75rem";
    heading.style.fontWeight = "700";
    heading.style.color = "#7e6ab7";
    heading.style.marginBottom = "0.5rem";
    const message = document.createElement("p");
    message.textContent = "Your kindness makes a difference in our community.";
    message.style.fontSize = "1rem";
    message.style.color = "#6b6b6b";
    message.style.marginBottom = "1.5rem";
    const img = document.createElement("img");
    img.src = src;
    img.alt = "Thank you";
    img.style.maxWidth = "100%";
    img.style.borderRadius = "12px";
    img.style.display = "block";
    img.style.margin = "0 auto";
    img.onerror = () => {
      console.error("Failed to load thank you GIF from:", src);
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
    return new Promise((resolve) => {
      const probe = new Image();
      probe.onload = () => {
        showThankYouGifModal("/images/thankyou.gif");
        resolve();
      };
      probe.onerror = () => resolve();
      probe.src = "/images/thankyou.gif";
    });
  }
  form.addEventListener("submit", async (e) => {
    e.preventDefault();
    errorMsg.style.display = "none";
    successMsg.style.display = "none";
    submitBtn.disabled = true;
    submitBtn.textContent = "Submitting...";
    const formData = new FormData(form);
    const orderNumber = (formData.get("orderNumber") || "").toString().trim();
    const eta = (formData.get("eta") || "").toString().trim();
    const fulfillerEmail = (formData.get("fulfillerEmail") || "").toString().trim();
    const contactMessage = (formData.get("contactMessage") || "").toString().trim();
    if (!orderNumber) {
      errorMsg.textContent = "Please enter the Grubhub order number.";
      errorMsg.style.display = "block";
      submitBtn.disabled = false;
      submitBtn.textContent = "Place Order";
      return;
    }
    if (!fulfillerEmail) {
      errorMsg.textContent = "Please provide your email so the requester can contact you.";
      errorMsg.style.display = "block";
      submitBtn.disabled = false;
      submitBtn.textContent = "Place Order";
      return;
    }
    if (!/^[A-Za-z0-9_-]{1,50}$/.test(orderNumber)) {
      errorMsg.textContent = "That doesn't look like a valid Grubhub order number. Please check and try again.";
      errorMsg.style.display = "block";
      submitBtn.disabled = false;
      submitBtn.textContent = "Place Order";
      return;
    }
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(fulfillerEmail)) {
      errorMsg.textContent = "Please enter a valid email address.";
      errorMsg.style.display = "block";
      submitBtn.disabled = false;
      submitBtn.textContent = "Place Order";
      return;
    }
    try {
      const body = { orderNumber };
      if (eta) body.eta = eta;
      if (fulfillerEmail) body.fulfillerEmail = fulfillerEmail;
      if (contactMessage) body.contactMessage = contactMessage;
      const resp = await fetch(`/api/request/${requestId}/fulfill`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body)
      });
      const result = await resp.json();
      if (!resp.ok) throw new Error(result.error || "Failed to fulfill request");
      if (orderNumberVal) orderNumberVal.textContent = escapeHtmlSafe(orderNumber);
      if (orderNumberDisplay) orderNumberDisplay.style.display = "block";
      successMsg.textContent = "Order placed \u2014 requester has been notified.";
      successMsg.style.display = "block";
      form.reset();
      tryShowThankYou();
      setTimeout(() => {
        window.location.href = "/";
      }, 3e3);
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      errorMsg.textContent = `Error: ${msg}`;
      errorMsg.style.display = "block";
    } finally {
      submitBtn.disabled = false;
      submitBtn.textContent = "Place Order";
    }
  });
});
export {
  WEB_ORDERING_UNAVAILABLE_MESSAGE,
  isLegacyWebOrderingAvailable,
  showLegacyWebOrderingUnavailable
};
//# sourceMappingURL=fulfill.js.map
