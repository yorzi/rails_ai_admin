import * as Turbo from "@hotwired/turbo";
import { Application, Controller } from "@hotwired/stimulus";
import railsToolViewsController from "./vendor/rails_tool_views_controller.js";

// Translated page text comes from the layout's data-raa-messages (en.yml
// rails_ai_admin.script). A host layout without it keeps the English text.
const FALLBACK_MESSAGES = {"leave_form": "Leave this form? Unsaved changes will be lost.", "session_attention": "Your session needs attention. Sign in in another tab, then resume here. Unsaved input stays only in this open tab.", "restored_partial": "Session restored. Some fields are no longer editable; their input was not restored. Review the form, then save explicitly.", "restored": "Session restored. Your input is ready for review. Nothing has been saved; submit explicitly when ready.", "return_changed": "Some list settings changed; return links use the current permitted list.", "recovery_failed": "Recovery was not completed. Sign in as the original user and tenant, then try again. Changed records, permissions, schema, time zone, expired recovery windows or completed requests require a fresh form. This tab still holds your input; nothing was submitted again."};
function message(key) {
  try {
    const translated = JSON.parse(document.body?.dataset.raaMessages || "{}")[key];
    if (typeof translated === "string" && translated !== "") return translated;
  } catch { /* fall back to English */ }
  return FALLBACK_MESSAGES[key];
}
const application = Application.start();
class DirtyFormController extends Controller {
  static values = { restored: Boolean };
  connect() {
    this.dirty = this.restoredValue;
    this.warnUnload = (event) => {
      if (this.dirty && !this.submitting) { event.preventDefault(); event.returnValue = ""; }
    };
    this.warnVisit = (event) => {
      if (this.dirty && !this.submitting && !window.confirm(message("leave_form"))) event.preventDefault();
    };
    window.addEventListener("beforeunload", this.warnUnload);
    document.addEventListener("turbo:before-visit", this.warnVisit);
  }
  change() { this.dirty = true; }
  submit() { this.submitting = true; }
  pause() { this.submitting = false; this.dirty = true; }
  finish(event) {
    this.submitting = false;
    if (event.detail.success) this.dirty = false;
  }
  disconnect() {
    window.removeEventListener("beforeunload", this.warnUnload);
    document.removeEventListener("turbo:before-visit", this.warnVisit);
  }
}
class FormRecoveryController extends Controller {
  static targets = ["notice", "message", "resume"];
  static values = { url: String, intent: String, timeZone: String, fields: Array, returnState: String };
  connect() {
    this.paused = false;
    this.pending = false;
    this.abortController = new AbortController();
    this.blockSubmit = (event) => {
      if (this.paused) { event.preventDefault(); event.stopImmediatePropagation(); }
    };
    this.element.addEventListener("submit", this.blockSubmit, true);
  }
  inspectResponse(event) {
    const response = event.detail.fetchResponse.response;
    const source = new URL(this.element.action, location.href);
    if (event.target !== this.element || source.origin !== location.origin ||
        response.url !== source.href || response.redirected ||
        response.headers.get("X-RailsAiAdmin-Form-Recovery") !== "session" ||
        ![401, 422].includes(response.status)) return;
    event.preventDefault();
    this.paused = true;
    this.pending = true;
    this.element.querySelectorAll('input[type=submit], button[type=submit]').forEach((button) => { button.disabled = true; });
    this.element.dispatchEvent(new CustomEvent("raa:form-paused", { bubbles: true }));
    this.show(message("session_attention"));
  }
  finished() {
    this.pending = false;
    if (this.paused) {
      this.resumeTarget.disabled = false;
      this.element.querySelectorAll('input[type=submit], button[type=submit]').forEach((button) => { button.disabled = true; });
    }
  }
  show(message) {
    this.messageTarget.textContent = message;
    this.noticeTarget.hidden = false;
    this.noticeTarget.focus();
  }
  snapshot() {
    const values = new Map();
    let bytes = 0;
    for (const [name, value] of new FormData(this.element)) {
      if (!/^record\[[a-z][a-z0-9_]*\]$/.test(name)) continue;
      // A chosen file cannot be kept across sign-in; the person picks it again.
      if (typeof File !== "undefined" && value instanceof File) continue;
      if (typeof value !== "string") throw new Error("Unsupported form input");
      bytes += new TextEncoder().encode(name + value).byteLength;
      if (bytes > 1048576) throw new Error("Form input bound exceeded");
      values.set(name, value);
      if (values.size > 128) throw new Error("Form input bound exceeded");
    }
    return values;
  }
  async resume() {
    if (!this.paused || this.pending) return;
    this.pending = true;
    this.resumeTarget.disabled = true;
    try {
      const url = new URL(this.urlValue, location.href);
      if (url.origin !== location.origin || url.search || url.hash) throw new Error("Invalid recovery path");
      const response = await fetch(url, { method: "GET", mode: "same-origin", credentials: "same-origin", redirect: "error", cache: "no-store", signal: this.abortController.signal,
        headers: { "Accept": "text/html", "X-RailsAiAdmin-Recovery-Intent": this.intentValue, "X-RailsAiAdmin-Return-State": this.returnStateValue } });
      if (!response.ok || response.redirected || response.url !== url.href || response.headers.get("X-RailsAiAdmin-Form-Recovery") !== "ready" ||
          !response.headers.get("Content-Type")?.startsWith("text/html")) throw new Error("Recovery was not authorized");
      const html = await response.text();
      if (new TextEncoder().encode(html).byteLength > 2097152) throw new Error("Form response bound exceeded");
      const doc = new DOMParser().parseFromString(html, "text/html");
      const form = doc.querySelector('form[data-controller~="raa-form-recovery"]');
      if (!form || form.querySelector('input[name="intent_ref"]')?.value !== this.intentValue ||
          form.querySelector('input[name="_method"]')?.value !== this.element.querySelector('input[name="_method"]')?.value ||
          form.dataset.raaFormRecoveryIntentValue !== this.intentValue || form.dataset.raaFormRecoveryTimeZoneValue !== this.timeZoneValue ||
          new URL(form.getAttribute("action"), url).href !== this.element.action || form.method !== this.element.method) throw new Error("Form binding changed");
      if (!this.element.isConnected) return;
      const values = this.snapshot();
      const allowed = JSON.parse(form.dataset.raaFormRecoveryFieldsValue);
      if (!Array.isArray(allowed) || allowed.some((name) => typeof name !== "string" || !/^[a-z][a-z0-9_]*$/.test(name))) throw new Error("Invalid form fields");
      const restored = new Set();
      for (const control of form.elements) {
        if (!allowed.some((name) => control.name === `record[${name}]`) || !values.has(control.name) || control.disabled || control.readOnly || !["INPUT", "SELECT", "TEXTAREA"].includes(control.tagName)) continue;
        const value = values.get(control.name);
        if (["file", "submit", "hidden", "button", "reset"].includes(control.type)) continue;
        if (["checkbox", "radio"].includes(control.type)) control.checked = control.value === value;
        else if (control.tagName === "SELECT" && ![...control.options].some((option) => option.value === value && !option.disabled)) continue;
        else control.value = value;
        restored.add(control.name);
      }
      form.dataset.raaDirtyFormRestoredValue = "true";
      const notice = form.querySelector('[data-raa-form-recovery-target="notice"]');
      notice.hidden = false;
      notice.querySelector('[data-raa-form-recovery-target="message"]').textContent =
        restored.size < values.size ? message("restored_partial") : message("restored");
      if (form.dataset.raaFormRecoveryReturnDiscardedValue === "true") {
        notice.querySelector('[data-raa-form-recovery-target="message"]').textContent += " " + message("return_changed");
      }
      form.querySelector('[data-raa-form-recovery-target="resume"]').hidden = true;
      const fresh = document.importNode(form, true);
      const meta = doc.querySelector('meta[name="csrf-token"]');
      if (meta && document.querySelector('meta[name="csrf-token"]')) document.querySelector('meta[name="csrf-token"]').content = meta.content;
      this.element.replaceWith(fresh);
      requestAnimationFrame(() => fresh.querySelector('[data-raa-form-recovery-target="notice"]').focus());
    } catch {
      if (this.element.isConnected) this.show(message("recovery_failed"));
    } finally {
      this.pending = false;
      if (this.element.isConnected) this.resumeTarget.disabled = false;
    }
  }
  disconnect() {
    this.abortController.abort();
    this.element.removeEventListener("submit", this.blockSubmit, true);
  }
}
class TabsController extends Controller {
  static targets = ["list", "tab", "panel"];
  connect() {
    if (!this.hasListTarget || this.tabTargets.length < 2) return;
    this.listTarget.setAttribute("role", "tablist");
    this.tabTargets.forEach((tab, index) => {
      tab.setAttribute("role", "tab");
      tab.setAttribute("aria-controls", this.panelTargets[index].id);
      this.panelTargets[index].setAttribute("role", "tabpanel");
      this.panelTargets[index].setAttribute("aria-labelledby", tab.id);
    });
    this.activate(Math.max(0, this.panelTargets.findIndex((panel) => panel.querySelector('[aria-invalid="true"]'))));
    this.form = this.element.closest("form");
    this.invalid = () => {
      const first = this.form.querySelector("input:invalid, select:invalid, textarea:invalid");
      if (first) this.showControl(first);
    };
    this.form?.addEventListener("invalid", this.invalid, true);
  }
  activate(index, focus = false) {
    this.tabTargets.forEach((tab, current) => {
      const selected = current === index;
      tab.setAttribute("aria-selected", String(selected));
      tab.tabIndex = selected ? 0 : -1;
      this.panelTargets[current].hidden = !selected;
    });
    if (focus) this.tabTargets[index].focus();
  }
  choose(event) {
    event.preventDefault();
    this.activate(this.tabTargets.indexOf(event.currentTarget));
  }
  keydown(event) {
    const current = this.tabTargets.indexOf(event.currentTarget);
    let next;
    if (event.key === "ArrowRight") next = (current + 1) % this.tabTargets.length;
    if (event.key === "ArrowLeft") next = (current + this.tabTargets.length - 1) % this.tabTargets.length;
    if (event.key === "Home") next = 0;
    if (event.key === "End") next = this.tabTargets.length - 1;
    if (event.key === " " || event.key === "Enter") next = current;
    if (next === undefined) return;
    event.preventDefault();
    this.activate(next, true);
  }
  showControl(control) {
    const index = this.panelTargets.findIndex((panel) => panel.contains(control));
    if (index >= 0 && this.hasListTarget) this.activate(index);
  }
  reveal(event) { this.showControl(event.target); }
  disconnect() {
    this.form?.removeEventListener("invalid", this.invalid, true);
    this.panelTargets.forEach((panel) => {
      panel.hidden = false;
      panel.removeAttribute("role");
      panel.removeAttribute("aria-labelledby");
    });
    this.tabTargets.forEach((tab) => {
      tab.removeAttribute("role");
      tab.removeAttribute("aria-controls");
      tab.removeAttribute("aria-selected");
      tab.removeAttribute("tabindex");
    });
    if (this.hasListTarget) this.listTarget.removeAttribute("role");
  }
}
class ErrorSummaryController extends Controller {
  connect() { this.element.focus(); }
  reveal(event) {
    const control = document.getElementById(event.currentTarget.dataset.raaTargetField);
    if (!control || !this.element.closest("form")?.contains(control)) return;
    event.preventDefault();
    control.dispatchEvent(new CustomEvent("raa:reveal", { bubbles: true }));
    control.focus();
  }
}
// Reloads the transcript frame while a turn is pending. Without JavaScript
// the transcript offers a plain Refresh link instead.
class PollController extends Controller {
  static values = { url: String };
  connect() {
    this.loaded = () => this.schedule();
    this.changed = () => this.schedule(1000, true);
    this.element.addEventListener("turbo:frame-load", this.loaded);
    this.element.addEventListener("turbo:submit-end", this.changed);
    this.schedule();
  }
  schedule(delay = 2000, force = false) {
    clearTimeout(this.timer);
    if (!force && !this.pending()) return;
    this.timer = setTimeout(() => {
      if (this.element.getAttribute("src")) this.element.reload();
      else this.element.setAttribute("src", this.urlValue);
    }, delay);
  }
  // Frame reloads replace children only, so the flag lives inside.
  pending() { return this.element.querySelector("[data-raa-pending]") !== null; }
  disconnect() {
    clearTimeout(this.timer);
    this.element.removeEventListener("turbo:frame-load", this.loaded);
    this.element.removeEventListener("turbo:submit-end", this.changed);
  }
}
// Enables "Capture selection" once a row is ticked. The boxes live in the
// table and join the form through form="…". Without JavaScript the button
// stays enabled and an empty submit returns to the list with a notice.
class SelectionController extends Controller {
  static targets = ["submit"];
  connect() {
    this.all = document.querySelector("[data-raa-select-all]");
    if (this.all) this.all.hidden = false;
    this.update = (event) => {
      const boxes = [...document.querySelectorAll(`input[type="checkbox"][form="${this.element.id}"]`)];
      if (event?.target === this.all) boxes.forEach((box) => { box.checked = this.all.checked; });
      const checked = boxes.filter((box) => box.checked).length;
      if (this.all) {
        this.all.checked = boxes.length > 0 && checked === boxes.length;
        this.all.indeterminate = checked > 0 && checked < boxes.length;
      }
      if (this.hasSubmitTarget) this.submitTarget.disabled = checked === 0;
    };
    document.addEventListener("change", this.update);
    this.update();
  }
  disconnect() { document.removeEventListener("change", this.update); }
}
// Fills a typed reference key from the target resource's search. Results are
// written with textContent only; the key input stays the submitted value.
// A rich-text editor without uploads: the admin stores text, not files, in
// Action Text content. Edits count as unsaved changes.
class RichTextController extends Controller {
  refuse(event) { event.preventDefault(); }
  change() { this.element.dispatchEvent(new Event("input", { bubbles: true })); }
}

class ReferencePickerController extends Controller {
  static targets = ["panel", "query", "status", "results", "current"];
  static values = { url: String, key: String, messages: Object };
  connect() {
    this.key = document.getElementById(this.keyValue);
    if (!this.key) return;
    this.panelTarget.hidden = false;
    this.sequence = 0;
  }
  disconnect() { clearTimeout(this.timer); this.abort?.abort(); }
  keydown(event) {
    // Enter in the search box must never submit the surrounding form.
    if (event.key === "Enter") {
      event.preventDefault();
      this.resultsTarget.querySelector("button")?.focus();
    } else if (event.key === "Escape") { this.clear(); }
  }
  search(event) {
    event.stopPropagation();
    clearTimeout(this.timer);
    this.timer = setTimeout(() => this.fetch(this.queryTarget.value.trim()), 250);
  }
  async fetch(term) {
    this.abort?.abort();
    if (term === "") { this.clear(); return; }
    const sequence = ++this.sequence;
    this.abort = new AbortController();
    this.statusTarget.textContent = this.messagesValue.searching;
    try {
      const url = new URL(this.urlValue, location.href);
      url.searchParams.set("q", term);
      const response = await fetch(url, { headers: { Accept: "application/json" }, credentials: "same-origin", signal: this.abort.signal });
      if (!response.ok || url.origin !== location.origin) throw new Error("search failed");
      const body = await response.json();
      if (sequence === this.sequence) this.render(Array.isArray(body.results) ? body.results : []);
    } catch (error) {
      if (error.name !== "AbortError" && sequence === this.sequence) {
        this.resultsTarget.replaceChildren();
        this.statusTarget.textContent = this.messagesValue.failed;
      }
    }
  }
  render(results) {
    const items = results.filter((result) => typeof result.id === "string" && typeof result.label === "string").map((result) => {
      const item = document.createElement("li");
      const button = document.createElement("button");
      button.type = "button";
      button.textContent = result.label;
      button.addEventListener("click", () => this.choose(result));
      item.append(button);
      return item;
    });
    this.resultsTarget.replaceChildren(...items);
    const template = items.length === 0 ? this.messagesValue.none : (items.length === 1 ? this.messagesValue.one : this.messagesValue.other);
    this.statusTarget.textContent = template.replace("%{count}", String(items.length));
  }
  choose(result) {
    this.key.value = result.id;
    this.key.dispatchEvent(new Event("input", { bubbles: true }));
    this.key.dispatchEvent(new Event("change", { bubbles: true }));
    this.currentTarget.textContent = this.messagesValue.chosen.replace("%{label}", result.label);
    this.currentTarget.hidden = false;
    this.clear();
    this.key.focus();
  }
  clear() {
    clearTimeout(this.timer);
    this.queryTarget.value = "";
    this.resultsTarget.replaceChildren();
    this.statusTarget.textContent = "";
  }
}
application.register("raa-selection", SelectionController);
application.register("raa-reference-picker", ReferencePickerController);
application.register("raa-rich-text", RichTextController);
// Review Surfaces carry data-controller="rails-tool-views" for saving and
// failure status text (RAA-019); the factory is rails_tool_views' own.
application.register("rails-tool-views", railsToolViewsController(Controller));
application.register("raa-poll", PollController);
application.register("raa-form-recovery", FormRecoveryController);
application.register("raa-dirty-form", DirtyFormController);
application.register("raa-tabs", TabsController);
application.register("raa-error-summary", ErrorSummaryController);
export { application, Turbo };
