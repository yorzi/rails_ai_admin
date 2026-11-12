// Vendored from rails_tool_views 1.0.2, app/assets/javascripts/rails_tool_views_controller.js (MIT).
// Keep in sync with the gemspec's rails_tool_views requirement; see frontend/licenses/README.md.
// Host imports and registers this factory with its own Stimulus application.
// No provider, generated code, or browser-owned policy participates in actions.
export default function railsToolViewsController(Controller) {
  return class extends Controller {
    static targets = ["status", "error"];
    // The server-rendered Surface supplies translated copy; these are fallbacks.
    static values = {
      revision: Number,
      saving: { type: String, default: "Saving changes…" },
      failed: { type: String, default: "Changes could not be saved. Review the message and try again." }
    };
    connect() {
      this.start = () => {
        this.element.setAttribute("aria-busy", "true");
        if (this.hasStatusTarget) this.statusTarget.textContent = this.savingValue;
      };
      this.end = (event) => {
        this.element.removeAttribute("aria-busy");
        if (!event.detail.success && this.hasStatusTarget) this.statusTarget.textContent = this.failedValue;
      };
      this.beforeStream = (event) => {
        const stream = event.target;
        if (stream.getAttribute("target") !== this.element.id) return;
        const incoming = stream.querySelector("template")?.content.firstElementChild;
        const revision = Number(incoming?.getAttribute("data-rails-tool-views-revision-value"));
        if (revision && revision < this.revisionValue) event.preventDefault();
        else incoming?.setAttribute("data-rails-tool-views-replaced", "");
      };
      this.element.ownerDocument.addEventListener("turbo:before-stream-render", this.beforeStream);
      this.element.addEventListener("turbo:submit-start", this.start);
      this.element.addEventListener("turbo:submit-end", this.end);
      // Only a rendered replacement announces a result; a page load keeps the reader's place.
      const replaced = this.element.hasAttribute("data-rails-tool-views-replaced");
      this.element.removeAttribute("data-rails-tool-views-replaced");
      if (this.hasErrorTarget) this.errorTarget.focus({ preventScroll: true });
      else if (replaced && this.hasStatusTarget) this.statusTarget.focus({ preventScroll: true });
    }
    disconnect() {
      this.element.ownerDocument.removeEventListener("turbo:before-stream-render", this.beforeStream);
      this.element.removeEventListener("turbo:submit-start", this.start);
      this.element.removeEventListener("turbo:submit-end", this.end);
    }
  };
}
