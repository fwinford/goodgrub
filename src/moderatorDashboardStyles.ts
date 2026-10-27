/*
 * Moderator dashboard stylesheet (W4-U1.2 CP5), served same-origin at
 * /moderation/assets/dashboard.css so the moderator CSP can use
 * `style-src 'self'`. Hand-written, no scripts, fonts, images or external
 * requests. Meaningful state (status, outcome, active hold) is always real
 * text in the markup; nothing here generates content.
 */
export const MODERATOR_STYLESHEET_PATH = "/moderation/assets/dashboard.css";

export const MODERATOR_STYLESHEET = `:root {
  --bg: #f3f4f6;
  --surface: #ffffff;
  --border: #dcdfe4;
  --text: #1f2430;
  --muted: #5b6472;
  --primary: #2563eb;
  --primary-hover: #1d4ed8;
  --secondary-text: #374151;
  --secondary-border: #c7cdd6;
  --secondary-bg-hover: #eef0f3;
  --danger: #b91c1c;
  --danger-hover: #991b1b;
  --focus: #1d4ed8;
  --radius-lg: 10px;
  --radius-sm: 6px;
  --space-1: 0.5rem;
  --space-2: 0.75rem;
  --space-3: 1rem;
  --space-4: 1.5rem;
  --space-5: 2rem;
}

* { box-sizing: border-box; }
html { -webkit-text-size-adjust: 100%; }

body {
  margin: 0;
  background: var(--bg);
  color: var(--text);
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
  font-size: 15px;
  line-height: 1.55;
}

/* Header and navigation */
header.site-header {
  display: flex;
  align-items: center;
  flex-wrap: wrap;
  gap: var(--space-2) var(--space-3);
  background: var(--surface);
  border-bottom: 1px solid var(--border);
  padding: var(--space-2) var(--space-4);
}
.brand { font-weight: 700; color: var(--text); margin-inline-end: var(--space-2); }
nav.primary-nav { display: flex; flex-wrap: wrap; gap: var(--space-1); }
nav.primary-nav a {
  color: var(--secondary-text);
  text-decoration: none;
  font-weight: 600;
  padding: var(--space-1) var(--space-2);
  border-radius: var(--radius-sm);
}
nav.primary-nav a:hover { background: var(--secondary-bg-hover); }
nav.primary-nav a[aria-current="page"] {
  color: var(--primary-hover);
  background: #eff6ff;
  box-shadow: inset 0 -2px 0 var(--primary);
}
header.site-header form { margin-inline-start: auto; }

/* Page content */
main {
  max-width: 760px;
  margin: 0 auto;
  padding: var(--space-4) var(--space-3) var(--space-5);
}

h1 {
  font-size: 1.5rem;
  font-weight: 700;
  margin: 0 0 var(--space-4);
  padding-bottom: var(--space-2);
  border-bottom: 1px solid var(--border);
}
h2 { font-size: 1.05rem; font-weight: 700; margin: 0 0 var(--space-2); }
h3 { font-size: 0.95rem; font-weight: 700; margin: 0 0 var(--space-1); }
p { margin: 0 0 var(--space-2); }
a { color: var(--primary-hover); }
a:hover { text-decoration-thickness: 2px; }
.muted { color: var(--muted); }
.help { color: var(--muted); font-size: 0.9em; }

/* Cards */
main > section,
main > ul,
main > form,
main > .empty-state,
.login-card {
  background: var(--surface);
  border: 1px solid var(--border);
  border-radius: var(--radius-lg);
  padding: var(--space-3) var(--space-4);
  margin: 0 0 var(--space-4);
  box-shadow: 0 1px 2px rgba(16, 24, 40, 0.04);
}
main section section {
  background: var(--bg);
  border: 1px solid var(--border);
  border-radius: var(--radius-sm);
  padding: var(--space-3);
  margin: 0 0 var(--space-3);
}
.empty-state { color: var(--muted); }
.visually-hidden {
  position: absolute;
  width: 1px;
  height: 1px;
  margin: -1px;
  padding: 0;
  overflow: hidden;
  clip: rect(0, 0, 0, 0);
  white-space: nowrap;
  border: 0;
}

/* Open / Closed switch */
.view-switch { display: flex; gap: var(--space-1); margin: 0 0 var(--space-3); }
.view-switch a {
  padding: var(--space-1) var(--space-3);
  border: 1px solid var(--secondary-border);
  border-radius: 999px;
  background: var(--surface);
  color: var(--secondary-text);
  font-weight: 600;
  text-decoration: none;
}
.view-switch a:hover { background: var(--secondary-bg-hover); }
.view-switch a[aria-current="page"] {
  background: var(--primary);
  border-color: var(--primary);
  color: #fff;
}

/* Report and suspension lists */
main > ul { list-style: none; }
main > ul > li {
  display: flex;
  flex-wrap: wrap;
  align-items: baseline;
  column-gap: var(--space-3);
  row-gap: var(--space-1);
  padding: var(--space-3) 0;
  border-bottom: 1px solid var(--border);
  min-width: 0;
}
main > ul > li:first-child { padding-top: 0; }
main > ul > li:last-child { border-bottom: none; padding-bottom: 0; }

.status-badge {
  display: inline-block;
  padding: 2px 8px;
  border-radius: 999px;
  font-size: 0.72rem;
  font-weight: 700;
  text-transform: uppercase;
  letter-spacing: 0.02em;
  white-space: nowrap;
}
.status-open { background: #fef3c7; color: #92400e; }
.status-closed { background: #e5e7eb; color: #374151; }
.status-active { background: #fee2e2; color: #991b1b; }
.status-hold { background: #dbeafe; color: #1e40af; margin-inline-start: var(--space-2); }

.reason { font-weight: 600; flex: 1 1 220px; min-width: 0; overflow-wrap: anywhere; }
.outcome { color: var(--secondary-text); font-size: 0.9em; overflow-wrap: anywhere; }
.row-open { flex: 0 0 auto; font-weight: 600; }
.timestamp { color: var(--muted); font-size: 0.85em; margin-inline-start: auto; }

main.page-reports > ul > li {
  display: grid;
  grid-template-columns: auto minmax(0, 1fr) auto;
  grid-template-areas:
    "badge reason action"
    ". meta meta"
    ". ref ref";
  align-items: baseline;
  row-gap: var(--space-1);
}
main.page-reports .status-badge { grid-area: badge; }
main.page-reports .reason { grid-area: reason; }
main.page-reports .row-open { grid-area: action; justify-self: end; }
main.page-reports .row-meta {
  grid-area: meta;
  display: flex;
  flex-wrap: wrap;
  column-gap: var(--space-3);
  color: var(--muted);
  font-size: 0.85em;
}
main.page-reports .row-meta .timestamp { margin-inline-start: 0; }
main.page-reports > ul > li { row-gap: var(--space-2); padding: var(--space-4) 0; }
main.page-reports > ul > li:first-child { padding-top: var(--space-2); }
main.page-reports > ul > li:last-child { padding-bottom: var(--space-2); }
main.page-reports aside.help { margin-top: var(--space-4); }
main.page-reports aside.help h2 { font-size: 0.95rem; margin: 0 0 var(--space-1); }
.hold-create { margin-top: var(--space-3); }
.hold-create > summary { cursor: pointer; font-weight: 600; color: var(--secondary-text); }
.hold-create[open] > summary { margin-bottom: var(--space-3); }

.ref-link, .ref-chip, .ref-text {
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  font-size: 0.8em;
  color: var(--secondary-text);
  overflow-wrap: anywhere;
  word-break: break-all;
}
.ref-link, .ref-chip {
  background: var(--bg);
  border: 1px solid var(--border);
  border-radius: var(--radius-sm);
  padding: 1px 6px;
  text-decoration: none;
}
.ref-chip { border-radius: 999px; padding: 1px 8px; }

/* Active suspensions */
main.page-suspensions > ul > li { flex-direction: column; align-items: stretch; }
.susp-meta {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  column-gap: var(--space-2);
  row-gap: var(--space-1);
  margin: 0 0 var(--space-2);
}
.participant { font-weight: 700; overflow-wrap: anywhere; }
.origin-chip {
  font-size: 0.78em;
  color: var(--secondary-text);
  background: var(--bg);
  border: 1px solid var(--border);
  border-radius: 999px;
  padding: 1px 8px;
}
.rationale {
  color: var(--secondary-text);
  padding: var(--space-2) var(--space-3);
  background: var(--bg);
  border-radius: var(--radius-sm);
  margin-bottom: var(--space-2);
  overflow-wrap: anywhere;
}
form.action-row { padding-top: var(--space-2); border-top: 1px dashed var(--border); }

/* Report detail */
.meta-line { padding: 0 var(--space-1); overflow-wrap: anywhere; }
.meta-line strong { color: var(--muted); font-weight: 600; margin-inline-end: var(--space-1); }
.notice {
  padding: var(--space-2) var(--space-3);
  background: #eff6ff;
  border: 1px solid #bfdbfe;
  border-radius: var(--radius-sm);
  color: #1e3a8a;
}
.readonly-note { background: #f9fafb; border-color: var(--secondary-border); color: var(--secondary-text); }
.review-due-note {
  display: inline-block;
  padding: 2px 8px;
  border-radius: 999px;
  background: #fef3c7;
  color: #92400e;
  font-size: 0.78em;
  font-weight: 600;
}
.decision { border-color: var(--secondary-border); }
.explanation-text { overflow-wrap: anywhere; white-space: pre-wrap; }

dl {
  display: grid;
  grid-template-columns: minmax(11rem, max-content) 1fr;
  gap: var(--space-1) var(--space-4);
  margin: 0;
}
dt { font-weight: 600; color: var(--muted); }
dd { margin: 0; overflow-wrap: anywhere; min-width: 0; }
section > ul { margin: var(--space-2) 0 0; padding-left: 1.25rem; }

.hold-actions { display: grid; gap: var(--space-3); }
.hold-actions form { padding-top: var(--space-2); border-top: 1px dashed var(--border); }
.footer-link { margin: var(--space-4) 0 0; padding-top: var(--space-3); border-top: 1px solid var(--border); font-size: 0.9em; }
.footer-link a { color: var(--secondary-text); }
.hold-actions form label:not(:has(input[type="checkbox"])) { margin-bottom: var(--space-1); }
.hold-actions form select { margin-bottom: var(--space-2); }
.hold-actions form .help { margin: 0 0 var(--space-2); }
ul.hold-list { list-style: none; padding: 0; margin: var(--space-3) 0 0; display: grid; gap: var(--space-3); }
ul.hold-list > li {
  border: 1px solid var(--border);
  border-radius: var(--radius-sm);
  padding: var(--space-3);
  min-width: 0;
}
ul.hold-list h3 { display: flex; flex-wrap: wrap; align-items: center; gap: var(--space-2); }
ul.hold-list dl { margin-bottom: var(--space-3); }

/* Forms */
label { display: block; font-weight: 600; margin: 0 0 var(--space-3); }
label:has(input[type="checkbox"]) {
  display: flex;
  align-items: flex-start;
  gap: var(--space-1);
  font-weight: 500;
}
label:has(input[type="checkbox"]) input { margin-top: 3px; }
label small { display: block; font-weight: 400; color: var(--muted); font-size: 0.85em; margin-top: var(--space-1); }
.field-hint { font-weight: 400; color: var(--muted); font-size: 0.85em; }
input:not([type="checkbox"]):not([type="hidden"]), select, textarea {
  display: block;
  width: 100%;
  margin-top: var(--space-1);
  padding: var(--space-1) var(--space-2);
  font: inherit;
  color: var(--text);
  background: var(--surface);
  border: 1px solid var(--secondary-border);
  border-radius: var(--radius-sm);
}
textarea { min-height: 4.5em; resize: vertical; }
input:focus-visible, select:focus-visible, textarea:focus-visible,
button:focus-visible, a:focus-visible {
  outline: 2px solid var(--focus);
  outline-offset: 2px;
}

/* Buttons: primary by default, secondary and destructive by class */
button[type="submit"] {
  appearance: none;
  border: 1px solid transparent;
  border-radius: var(--radius-sm);
  padding: var(--space-1) var(--space-3);
  font: inherit;
  font-weight: 600;
  cursor: pointer;
  background: var(--primary);
  color: #fff;
}
button[type="submit"]:hover { background: var(--primary-hover); }
button.btn-secondary {
  background: transparent;
  border-color: var(--secondary-border);
  color: var(--secondary-text);
}
button.btn-secondary:hover { background: var(--secondary-bg-hover); }
button.btn-danger { background: var(--danger); }
button.btn-danger:hover { background: var(--danger-hover); }

/* Sign-in */
body.page-login { padding: 10vh var(--space-3) var(--space-5); }
.login-card { max-width: 420px; margin: 0 auto; padding: var(--space-4); }
.login-card .brand-line { text-align: center; color: var(--muted); font-weight: 600; margin: 0 0 var(--space-1); }
.login-card h1 { text-align: center; border-bottom: none; padding-bottom: 0; margin-bottom: var(--space-3); }
.login-card [role="alert"] {
  padding: var(--space-2) var(--space-3);
  background: #fef2f2;
  border: 1px solid #fecaca;
  border-radius: var(--radius-sm);
  color: #991b1b;
}
.login-card button[type="submit"] { width: 100%; padding: var(--space-2) var(--space-3); }

@media (max-width: 640px) {
  main { padding: var(--space-3) var(--space-2) var(--space-4); }
  header.site-header { padding: var(--space-2); }
  header.site-header form { margin-inline-start: 0; }
  main > section, main > ul, main > form, main > .empty-state { padding: var(--space-3); }
  dl { grid-template-columns: 1fr; }
  dt { margin-top: var(--space-2); }
  dt:first-child { margin-top: 0; }
  .timestamp { margin-inline-start: 0; flex-basis: 100%; }
}
`;
