import { Controller } from "@hotwired/stimulus";

export default class QueriesController extends Controller {
  static targets = [
    "box", "toggle", "count", "star", "panel", "list", "empty", "footer", "footerLabel", "rowTemplate",
    "savePanel", "saveTitle", "saveFilter", "saveFlags", "name", "saveButton", "hint", "savedRow",
  ];
  static values = {
    logFilePath: String,
    endpoint: String,
  };

  connect() {
    this.queries = [];
    this.activeQueryId = null;
    this.pendingDeleteId = null;
    this.renamingId = null;

    this.boundCloseOnOutsideClick = (event) => {
      if (!this.boxTarget.contains(event.target)) this.close();
    };
    document.addEventListener("click", this.boundCloseOnOutsideClick);

    this.load();
  }

  disconnect() {
    document.removeEventListener("click", this.boundCloseOnOutsideClick);
  }

  get #menuOpen() {
    return !this.panelTarget.hidden;
  }

  get #saveOpen() {
    return !this.savePanelTarget.hidden;
  }

  toggle() {
    this.#menuOpen ? this.close() : this.#openMenu();
  }

  toggleSave() {
    this.#saveOpen ? this.close() : this.openSave();
  }

  openSave() {
    if (!this.#hasFilter) return;

    this.close();
    const current = this.#current;
    const name = this.#matching?.name ?? this.#active?.name ?? current.filter;

    this.saveFilterTarget.textContent = current.filter;
    this.saveFlagsTarget.replaceChildren(...this.#flags(current.regexpMode, current.caseInsensitive));
    this.nameTarget.value = name;
    this.savePanelTarget.hidden = false;
    this.starTarget.setAttribute("aria-expanded", "true");
    this.#renderSavePanel();

    this.nameTarget.focus();
    this.nameTarget.select();
  }

  close({ restoreFocus = false } = {}) {
    if (!this.#menuOpen && !this.#saveOpen) return;

    const trigger = this.#saveOpen ? this.starTarget : this.toggleTarget;
    this.panelTarget.hidden = true;
    this.savePanelTarget.hidden = true;
    this.toggleTarget.setAttribute("aria-expanded", "false");
    this.starTarget.setAttribute("aria-expanded", "false");
    this.pendingDeleteId = null;
    this.renamingId = null;
    if (restoreFocus) trigger.focus();
  }

  navigate(event) {
    if (!this.#menuOpen && !this.#saveOpen) return;

    if (event.key === "Escape") {
      event.preventDefault();
      event.stopPropagation();
      this.close({ restoreFocus: true });
      return;
    }

    if (!this.#menuOpen || !["ArrowDown", "ArrowUp"].includes(event.key)) return;

    const items = [...this.panelTarget.querySelectorAll(".saved-search__apply, .saved-searches__footer-button")]
      .filter((item) => item.checkVisibility());
    const index = items.indexOf(document.activeElement);
    if (items.length === 0) return;

    event.preventDefault();
    const step = event.key === "ArrowDown" ? 1 : -1;
    items[index === -1 ? 0 : (index + step + items.length) % items.length].focus();
  }

  refresh() {
    this.#render();
  }

  cleared() {
    this.activeQueryId = null;
    this.close();
    this.#render();
  }

  nameChanged() {
    this.#renderSavePanel();
  }

  async save(event) {
    event.preventDefault();

    const name = this.nameTarget.value.trim();
    const current = this.#current;
    if (!name || !this.#hasFilter) return;

    const matching = this.#matching;
    if (matching && matching.name === name) {
      this.activeQueryId = matching.id;
      this.close({ restoreFocus: true });
      this.#render();
      return;
    }

    const existing = matching ?? this.#findByName(name);
    const attributes = matching
      ? { name }
      : { name, filter: current.filter, regexp_mode: current.regexpMode, case_insensitive: current.caseInsensitive };
    const query = await this.#request(existing ? this.#url(`/${existing.id}`) : this.#url(), {
      method: existing ? "PATCH" : "POST",
      body: JSON.stringify({ query: attributes }),
    });
    if (!query) return;

    this.#store(query);
    this.activeQueryId = query.id;
    this.close({ restoreFocus: true });
    this.#render();
    this.#showMessage(matching ? `Renamed to "${query.name}"` : `${existing ? "Updated" : "Saved as"} "${query.name}"`, "success");
  }

  apply(event) {
    const query = this.#find(this.#queryId(event));
    if (!query || !this.#streamer) return;

    this.activeQueryId = query.id;
    this.#streamer.applySearch({
      filter: query.filter,
      regexpMode: query.regexp_mode,
      caseInsensitive: query.case_insensitive,
    });
    this.close();
    this.#render();
    this.#streamer.filterInputTarget.focus();
  }

  rename(event) {
    event.stopPropagation();
    this.renamingId = this.#queryId(event);
    this.pendingDeleteId = null;
    this.#renderList();

    const input = this.#row(this.renamingId)?.querySelector(".saved-search__rename-input");
    input?.focus();
    input?.select();
  }

  renameKey(event) {
    if (event.key === "Enter") {
      event.preventDefault();
      event.currentTarget.blur();
    } else if (event.key === "Escape") {
      event.preventDefault();
      event.stopPropagation();
      this.renamingId = null;
      this.#renderList();
      this.#row(this.#queryId(event))?.querySelector(".saved-search__apply")?.focus();
    }
  }

  async commitRename(event) {
    const id = this.#queryId(event);
    if (this.renamingId !== id) return;

    this.renamingId = null;
    const query = this.#find(id);
    const name = event.currentTarget.value.trim();
    if (!query || !name || name === query.name) {
      this.#renderList();
      return;
    }

    const renamed = await this.#request(this.#url(`/${id}`), {
      method: "PATCH",
      body: JSON.stringify({ query: { name } }),
    });
    if (renamed) this.#store(renamed, { keepPosition: true });
    this.#render();
  }

  async destroy(event) {
    event.stopPropagation();
    const id = this.#queryId(event);

    if (this.pendingDeleteId !== id) {
      this.pendingDeleteId = id;
      this.#renderList();
      this.#row(id)?.querySelector(".saved-search__delete")?.focus();
      return;
    }

    this.pendingDeleteId = null;
    if (await this.#delete(id)) this.toggleTarget.focus();
  }

  async removeCurrent() {
    const matching = this.#matching;
    if (!matching) return;

    this.close();
    if (await this.#delete(matching.id)) this.starTarget.focus();
  }

  async load() {
    const data = await this.#request(this.#url());
    if (!data) return;

    this.queries = data.queries;
    this.#render();
  }

  #openMenu() {
    this.close();
    this.panelTarget.hidden = false;
    this.toggleTarget.setAttribute("aria-expanded", "true");
    this.#render();

    const matching = this.#matching;
    const first = (matching && this.#row(matching.id)) || this.listTarget.querySelector(".saved-search");
    (first?.querySelector(".saved-search__apply") ?? this.footerTarget.querySelector("button")).focus();
  }

  async #delete(id) {
    const query = this.#find(id);
    const deleted = await this.#request(this.#url(`/${id}`), { method: "DELETE" });
    if (deleted === null) return false;

    this.queries = this.queries.filter((q) => q.id !== id);
    if (this.activeQueryId === id) this.activeQueryId = null;
    this.#render();
    this.#showMessage(`Deleted "${query?.name}"`, "success");
    return true;
  }

  #store(query, { keepPosition = false } = {}) {
    const index = this.queries.findIndex((q) => q.id === query.id);
    if (keepPosition && index !== -1) {
      this.queries = this.queries.with(index, query);
    } else {
      this.queries = [query, ...this.queries.filter((q) => q.id !== query.id)];
    }
  }

  #render() {
    this.#renderField();
    if (this.#menuOpen) this.#renderMenu();
    if (this.#saveOpen) this.#renderSavePanel();
  }

  #renderField() {
    const matching = this.#matching;
    const count = this.queries.length;

    this.countTarget.textContent = count > 0 ? count : "";
    this.toggleTarget.title = count > 0 ? `Saved searches (${count})` : "Saved searches";

    this.starTarget.disabled = !this.#hasFilter;
    this.starTarget.classList.toggle("saved-searches__star--saved", Boolean(matching));
    this.starTarget.title = !this.#hasFilter
      ? "Type a pattern to save it"
      : matching ? `Saved as "${matching.name}"` : "Save this search";
    this.starTarget.setAttribute("aria-label", this.starTarget.title);
  }

  #renderMenu() {
    this.emptyTarget.hidden = this.queries.length > 0;
    this.#renderList();

    const showFooter = this.#hasFilter && !this.#matching;
    this.footerTarget.hidden = !showFooter;
    if (showFooter) {
      this.footerLabelTarget.textContent = this.#edited
        ? `Save changes to "${this.#active.name}"…`
        : `Save current search "${this.#current.filter}"`;
    }
  }

  #renderList() {
    const matching = this.#matching;
    const edited = this.#edited;

    this.listTarget.replaceChildren(...this.queries.map((query) => {
      const item = this.rowTemplateTarget.content.firstElementChild.cloneNode(true);
      item.dataset.queryId = query.id;
      item.toggleAttribute("aria-current", matching?.id === query.id);

      const apply = item.querySelector(".saved-search__apply");
      apply.title = `Apply "${query.name}"`;
      item.querySelector(".saved-search__name").textContent = query.name;
      item.querySelector(".saved-search__check").toggleAttribute("hidden", matching?.id !== query.id);
      item.querySelector(".saved-search__edited").hidden = !(edited && this.activeQueryId === query.id);
      item.querySelector(".saved-search__filter").textContent = query.filter;
      item.querySelector(".saved-search__flags").replaceChildren(...this.#flags(query.regexp_mode, query.case_insensitive));

      const renaming = this.renamingId === query.id;
      const input = item.querySelector(".saved-search__rename-input");
      input.hidden = !renaming;
      input.value = query.name;
      input.setAttribute("aria-label", `New name for "${query.name}"`);
      apply.hidden = renaming;

      const rename = item.querySelector(".saved-search__rename");
      rename.hidden = renaming;
      rename.title = `Rename "${query.name}"`;
      rename.setAttribute("aria-label", rename.title);

      const remove = item.querySelector(".saved-search__delete");
      const confirming = this.pendingDeleteId === query.id;
      remove.hidden = renaming;
      remove.classList.toggle("saved-search__delete--confirm", confirming);
      remove.title = confirming ? "Click again to delete" : `Delete "${query.name}"`;
      remove.setAttribute("aria-label", remove.title);

      return item;
    }));
  }

  #renderSavePanel() {
    const matching = this.#matching;
    const name = this.nameTarget.value.trim();
    const byName = name === "" ? undefined : this.#findByName(name);
    const replacing = byName && byName.id !== matching?.id ? byName : undefined;
    const active = this.#active;

    let title = "Save this search";
    let label = "Save";
    let hint = "Saved searches show up in the list next to the star.";
    if (matching) {
      title = "Saved search";
      label = name === matching.name ? "Done" : "Rename";
      hint = "Change the name, or press Done.";
    } else if (replacing) {
      label = "Update";
      hint = `Replaces the pattern saved as "${replacing.name}".`;
    } else if (this.#edited) {
      title = "Save changes";
      hint = `Keep the name "${active.name}" to update it, or type a new name to save a copy.`;
    }

    this.saveTitleTarget.textContent = title;
    this.saveButtonTarget.textContent = label;
    this.saveButtonTarget.disabled = name === "";
    this.hintTarget.textContent = hint;
    this.hintTarget.classList.toggle("save-search__hint--warning", Boolean(replacing));
    this.savedRowTarget.hidden = !matching;
  }

  #flags(regexpMode, caseInsensitive) {
    return [[regexpMode, "regexp"], [caseInsensitive, "ignore case"]]
      .filter(([on]) => on)
      .map(([, label]) => {
        const flag = document.createElement("span");
        flag.className = "saved-search__flag";
        flag.textContent = label;
        return flag;
      });
  }

  get #current() {
    return this.#streamer?.currentSearch() ?? { filter: "", regexpMode: false, caseInsensitive: false };
  }

  get #hasFilter() {
    return this.#current.filter.trim() !== "";
  }

  get #matching() {
    if (!this.#hasFilter) return undefined;

    const current = this.#current;
    return this.queries.find((query) =>
      query.filter === current.filter &&
      query.regexp_mode === current.regexpMode &&
      query.case_insensitive === current.caseInsensitive);
  }

  get #active() {
    return this.#find(this.activeQueryId);
  }

  get #edited() {
    return Boolean(this.#active && this.#hasFilter && !this.#matching);
  }

  #queryId(event) {
    return Number(event.currentTarget.closest(".saved-search").dataset.queryId);
  }

  #row(id) {
    return this.listTarget.querySelector(`.saved-search[data-query-id="${id}"]`);
  }

  #find(id) {
    return this.queries.find((q) => q.id === id);
  }

  #findByName(name) {
    const key = name.toLowerCase();
    return this.queries.find((q) => q.name.toLowerCase() === key);
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
    return this.application.getControllerForElementAndIdentifier(this.element, "log-streamer");
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
