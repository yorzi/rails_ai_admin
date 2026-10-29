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
application.register("raa-dirty-form", DirtyFormController);
export { application, Turbo };
