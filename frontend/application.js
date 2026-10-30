import * as Turbo from "@hotwired/turbo";
import { Application, Controller } from "@hotwired/stimulus";

const application = Application.start();
class DirtyFormController extends Controller {
  connect() {
    this.dirty = false;
    this.warnUnload = (event) => {
      if (this.dirty && !this.submitting) { event.preventDefault(); event.returnValue = ""; }
    };
    this.warnVisit = (event) => {
      if (this.dirty && !this.submitting && !window.confirm("Leave this form? Unsaved changes will be lost.")) event.preventDefault();
    };
    window.addEventListener("beforeunload", this.warnUnload);
    document.addEventListener("turbo:before-visit", this.warnVisit);
  }
  change() { this.dirty = true; }
  submit() { this.submitting = true; }
  finish(event) {
    this.submitting = false;
    if (event.detail.success) this.dirty = false;
  }
  disconnect() {
    window.removeEventListener("beforeunload", this.warnUnload);
    document.removeEventListener("turbo:before-visit", this.warnVisit);
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
application.register("raa-dirty-form", DirtyFormController);
application.register("raa-tabs", TabsController);
application.register("raa-error-summary", ErrorSummaryController);
export { application, Turbo };
