import { Controller } from "@hotwired/stimulus";

export default class QueriesController extends Controller {
  static targets = ["toggle", "count", "panel", "name", "saveButton", "hint", "list"];
  static values = {
    logFilePath: String,
    endpoint: String,
  };

  connect() {
    this.queries = [];
    this.activeQueryId = null;
    this.pendingDeleteId = null;

    this.boundCloseOnOutsideClick = (event) => {
      if (this.isOpen && !this.element.contains(event.target)) this.close();
    };
    document.addEventListener("click", this.boundCloseOnOutsideClick);

    this.load();
  }

  disconnect() {
    document.removeEventListener("click", this.boundCloseOnOutsideClick);
  }

  get isOpen() {
    return !this.panelTarget.hidden;
  }

  toggle() {
    this.isOpen ? this.close() : this.open();
  }

  open() {
    this.pendingDeleteId = null;
    this.panelTarget.hidden = false;
    this.toggleTarget.setAttribute("aria-expanded", "true");

    const active = this.#find(this.activeQueryId);
    this.nameTarget.value = active?.name ?? "";
    this.#render();

    this.nameTarget.focus();
    this.nameTarget.select();
  }

  close({ restoreFocus = false } = {}) {
    if (!this.isOpen) return;

    this.panelTarget.hidden = true;
    this.toggleTarget.setAttribute("aria-expanded", "false");
    if (restoreFocus) this.toggleTarget.focus();
  }

  navigate(event) {
    if (event.key === "Escape") {
      event.preventDefault();
      this.close({ restoreFocus: true });
      return;
    }

    if (!["ArrowDown", "ArrowUp"].includes(event.key)) return;

    const items = [this.nameTarget, ...this.listTarget.querySelectorAll(".saved-search__apply")];
    const index = items.indexOf(document.activeElement);
    if (index === -1) return;

    event.preventDefault();
    const step = event.key === "ArrowDown" ? 1 : -1;
    items[(index + step + items.length) % items.length].focus();
  }

  nameChanged() {
    this.#renderSaveButton();
  }

  async save(event) {
    event.preventDefault();

    const name = this.nameTarget.value.trim();
    const search = this.#streamer?.currentSearch();
    if (!name || !search || search.filter.trim() === "") return;

    const existing = this.#findByName(name);
    const url = existing ? this.#url(`/${existing.id}`) : this.#url();
    const query = await this.#request(url, {
      method: existing ? "PATCH" : "POST",
      body: JSON.stringify({
        query: { name, filter: search.filter, regexp_mode: search.regexpMode, case_insensitive: search.caseInsensitive },
      }),
    });
    if (!query) return;

    this.queries = [query, ...this.queries.filter((q) => q.id !== query.id)];
    this.activeQueryId = query.id;
    this.#render();
    this.close({ restoreFocus: true });
    this.#showMessage(`${existing ? "Updated" : "Saved"} "${query.name}"`, "success");
  }

  apply(event) {
    const query = this.#find(Number(event.currentTarget.dataset.queryId));
    if (!query || !this.#streamer) return;

    this.activeQueryId = query.id;
    this.#streamer.applySearch({
      filter: query.filter,
      regexpMode: query.regexp_mode,
      caseInsensitive: query.case_insensitive,
    });
    this.close();
    this.#streamer.filterInputTarget.focus();
  }

  async destroy(event) {
    event.stopPropagation();
    const id = Number(event.currentTarget.dataset.queryId);

    if (this.pendingDeleteId !== id) {
      this.pendingDeleteId = id;
      this.#render();
      this.listTarget.querySelector(`.saved-search__delete[data-query-id="${id}"]`)?.focus();
      return;
    }

    this.pendingDeleteId = null;
    const deleted = await this.#request(this.#url(`/${id}`), { method: "DELETE" });
    if (deleted === null) return;

    const query = this.#find(id);
    this.queries = this.queries.filter((q) => q.id !== id);
    if (this.activeQueryId === id) this.activeQueryId = null;
    this.#render();
    this.nameTarget.focus();
    this.#showMessage(`Deleted "${query?.name}"`, "success");
  }

  async load() {
    const data = await this.#request(this.#url());
    if (!data) return;

    this.queries = data.queries;
    this.#render();
  }

  #render() {
    this.#renderCount();
    this.#renderSaveButton();
    this.#renderList();
  }

  #renderCount() {
    this.countTarget.textContent = this.queries.length > 0 ? this.queries.length : "";
  }

  #renderSaveButton() {
    const search = this.#streamer?.currentSearch();
    const hasFilter = search && search.filter.trim() !== "";
    const existing = this.#findByName(this.nameTarget.value.trim());

    this.saveButtonTarget.textContent = existing ? "Update" : "Save";
    this.saveButtonTarget.disabled = !hasFilter || this.nameTarget.value.trim() === "";
    this.hintTarget.textContent = !hasFilter
      ? "Type a query first, then save it here."
      : existing
        ? `Replaces "${existing.name}" with the current query.`
        : "Saves the current query with its Regexp and Ignore case settings.";
  }

  #renderList() {
    const current = this.#streamer?.currentSearch();

    if (this.queries.length === 0) {
      const empty = document.createElement("li");
      empty.className = "saved-searches__empty";
      empty.textContent = "No saved searches yet";
      this.listTarget.replaceChildren(empty);
      return;
    }

    this.listTarget.replaceChildren(...this.queries.map((query) => {
      const item = document.createElement("li");
      item.className = "saved-search";
      if (current && this.#matches(query, current)) item.setAttribute("aria-current", "true");

      const apply = document.createElement("button");
      apply.type = "button";
      apply.className = "saved-search__apply";
      apply.dataset.queryId = query.id;
      apply.dataset.action = "queries#apply";
      apply.title = `Apply "${query.name}"`;

      const name = document.createElement("span");
      name.className = "saved-search__name";
      name.textContent = query.name;

      const filter = document.createElement("code");
      filter.className = "saved-search__filter";
      filter.textContent = query.filter;

      apply.append(name, filter, ...this.#flags(query));

      const remove = document.createElement("button");
      remove.type = "button";
      remove.className = "saved-search__delete";
      remove.dataset.queryId = query.id;
      remove.dataset.action = "queries#destroy";
      const confirming = this.pendingDeleteId === query.id;
      remove.classList.toggle("saved-search__delete--confirm", confirming);
      remove.textContent = confirming ? "Delete?" : "×";
      remove.title = confirming ? "Click again to delete" : `Delete "${query.name}"`;
      remove.setAttribute("aria-label", remove.title);

      item.append(apply, remove);
      return item;
    }));
  }

  #flags(query) {
    return [
      [query.regexp_mode, ".*", "Regexp"],
      [query.case_insensitive, "Aa", "Ignore case"],
    ].filter(([on]) => on).map(([, label, title]) => {
      const flag = document.createElement("span");
      flag.className = "saved-search__flag";
      flag.textContent = label;
      flag.title = title;
      return flag;
    });
  }

  #matches(query, search) {
    return query.filter === search.filter &&
      query.regexp_mode === search.regexpMode &&
      query.case_insensitive === search.caseInsensitive;
  }

  #find(id) {
    return this.queries.find((q) => q.id === id);
  }

  #findByName(name) {
    const key = name.toLowerCase();
    return key === "" ? undefined : this.queries.find((q) => q.name.toLowerCase() === key);
  }

  #url(suffix = "") {
    return `${this.endpointValue}${suffix}?log_file_path=${encodeURIComponent(this.logFilePathValue)}`;
  }

  async #request(url, options = {}) {
    try {
      const response = await fetch(url, {
        ...options,
        headers: {
          Accept: "application/json",
          "Content-Type": "application/json",
          "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || "",
        },
      });
      const body = response.status === 204 ? {} : await response.json().catch(() => ({}));

      if (!response.ok) {
        this.#showMessage(body.error || `Saved searches: request failed (${response.status})`, "error");
        return null;
      }
      return body;
    } catch {
      this.#showMessage("Saved searches are unreachable", "error");
      return null;
    }
  }

  get #streamer() {
    const element = this.element.closest('[data-controller~="log-streamer"]');
    return element && this.application.getControllerForElementAndIdentifier(element, "log-streamer");
  }

  #showMessage(message, type) {
    const messageElement = this.#streamer?.messageTarget;
    if (!messageElement) return;

    const span = document.createElement("span");
    span.className = type === "error" ? "error-message" : "success-message";
    span.textContent = message;
    messageElement.replaceChildren(span);

    setTimeout(() => {
      if (span.isConnected) span.remove();
    }, 4000);
  }
}
