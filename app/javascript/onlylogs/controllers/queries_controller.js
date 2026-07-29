import { Controller } from "@hotwired/stimulus";

export default class QueriesController extends Controller {
  static targets = ["saveButton", "loadButton", "saveModal", "queryName", "queriesList"];
  static values = { logFilePath: String };

  connect() {
    this.queries = [];
    this.dropdownOpen = false;

    // Verify required targets exist
    if (!this.hasSaveModalTarget || !this.hasQueriesListTarget) {
      console.warn("Queries controller: Missing required targets. saveModal:", this.hasSaveModalTarget, "queriesList:", this.hasQueriesListTarget);
      return;
    }

    // Close dropdown when clicking outside
    document.addEventListener("click", (e) => this.#handleDocumentClick(e));

    this.loadQueries();
  }

  get logStreamerController() {
    return this.#findLogStreamerController();
  }

  toggleQueriesDropdown() {
    this.dropdownOpen = !this.dropdownOpen;
    this.#updateDropdownVisibility();
  }

  #updateDropdownVisibility() {
    if (!this.hasQueriesListTarget || !this.hasLoadButtonTarget) return;

    if (this.dropdownOpen) {
      this.queriesListTarget.classList.add("open");
      this.loadButtonTarget.classList.add("open");
    } else {
      this.queriesListTarget.classList.remove("open");
      this.loadButtonTarget.classList.remove("open");
    }
  }

  #handleDocumentClick(e) {
    if (!this.element.contains(e.target)) {
      this.dropdownOpen = false;
      this.#updateDropdownVisibility();
    }
  }

  openSaveModal() {
    if (!this.hasSaveModalTarget) {
      console.warn("saveModal target not found");
      return;
    }

    this.saveModalTarget.classList.remove("hidden");

    if (this.hasQueryNameTarget) {
      this.queryNameTarget.value = "";
      setTimeout(() => this.queryNameTarget.focus(), 100);
    }
  }

  closeSaveModal() {
    if (!this.hasSaveModalTarget) return;
    this.saveModalTarget.classList.add("hidden");
  }

  async saveQuery(e) {
    if (e instanceof KeyboardEvent && e.key !== 'Enter') {
      return;
    }
    e?.preventDefault();

    if (!this.hasQueryNameTarget) {
      this.#showMessage("Query name input not found", "error");
      return;
    }

    const name = this.queryNameTarget.value.trim();
    if (!name) {
      this.#showMessage("Query name cannot be empty", "error");
      return;
    }

    const filter = this.logStreamerController?.filterInputTarget?.value || "";
    const regexpMode = this.logStreamerController?.regexpModeValue || false;

    try {
      const response = await fetch(`/onlylogs/queries`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": this.#csrfToken(),
        },
        body: JSON.stringify({
          log_file_path: this.logFilePathValue,
          name: name,
          filter: filter,
          regexp_mode: regexpMode,
        }),
      });

      if (!response.ok) {
        const error = await response.json();
        this.#showMessage(error.error || "Failed to save query", "error");
        return;
      }

      const query = await response.json();
      this.queries.unshift(query);

      this.closeSaveModal();
      this.#showMessage(`Query "${name}" saved`, "success");
      this.#updateQueriesList();
    } catch (error) {
      this.#showMessage(`Error saving query: ${error.message}`, "error");
    }
  }

  async loadQuery(queryId) {
    const query = this.queries.find((q) => q.id === queryId);
    if (!query) return;

    // Update filter and regexp mode in log streamer
    if (this.logStreamerController) {
      this.logStreamerController.filterInputTarget.value = query.filter;
      this.logStreamerController.regexpModeValue = query.regexp_mode;
      this.logStreamerController.regexpModeTarget.checked = query.regexp_mode;

      // Trigger filter application
      this.logStreamerController.applyFilter();

      this.#showMessage(`Query "${query.name}" loaded`, "success");
    }
  }

  async deleteQuery(queryId, e) {
    e?.stopPropagation();

    if (
      !confirm("Are you sure you want to delete this query?")
    ) {
      return;
    }

    try {
      const response = await fetch(
        `/onlylogs/queries/${queryId}?log_file_path=${encodeURIComponent(
          this.logFilePathValue
        )}`,
        {
          method: "DELETE",
          headers: {
            "X-CSRF-Token": this.#csrfToken(),
          },
        }
      );

      if (!response.ok) {
        const error = await response.json();
        this.#showMessage(error.error || "Failed to delete query", "error");
        return;
      }

      this.queries = this.queries.filter((q) => q.id !== queryId);

      this.#showMessage("Query deleted", "success");
      this.#updateQueriesList();
    } catch (error) {
      this.#showMessage(`Error deleting query: ${error.message}`, "error");
    }
  }

  async loadQueries() {
    try {
      const response = await fetch(
        `/onlylogs/queries?log_file_path=${encodeURIComponent(
          this.logFilePathValue
        )}`,
        {
          headers: {
            "X-CSRF-Token": this.#csrfToken(),
          },
        }
      );

      if (!response.ok) {
        console.error("Failed to load queries");
        return;
      }

      const data = await response.json();
      this.queries = data.queries || [];
      this.#updateQueriesList();
    } catch (error) {
      console.error("Error loading queries:", error);
    }
  }

  #updateQueriesList() {
    if (!this.hasQueriesListTarget) return;

    const container = this.queriesListTarget;
    container.innerHTML = "";

    if (this.queries.length === 0) {
      container.innerHTML =
        '<div class="queries-list-empty">No saved queries</div>';
      return;
    }

    this.queries.forEach((query) => {
      const item = document.createElement("div");
      item.className = "queries-list-item";

      const nameEl = document.createElement("span");
      nameEl.className = "queries-list-name";
      nameEl.textContent = query.name;
      nameEl.style.cursor = "pointer";
      nameEl.addEventListener("click", () => this.loadQuery(query.id));
      item.appendChild(nameEl);

      const deleteBtn = document.createElement("button");
      deleteBtn.className = "queries-list-delete";
      deleteBtn.textContent = "🗑️";
      deleteBtn.title = "Delete this search";
      deleteBtn.addEventListener("click", (e) => this.deleteQuery(query.id, e));
      item.appendChild(deleteBtn);

      container.appendChild(item);
    });
  }

  #findLogStreamerController() {
    let current = this.element;

    // Search up the DOM tree for an element with log-streamer controller
    while (current) {
      if (current.hasAttribute("data-controller")) {
        const controllers = current.getAttribute("data-controller").split(" ");
        if (controllers.includes("log-streamer")) {
          // Found the log-streamer element, now get its controller instance
          try {
            const app = this.application;
            return app.getControllerForElementAndIdentifier(current, 'log-streamer');
          } catch (e) {
            console.error('Failed to get log-streamer controller:', e);
            return null;
          }
        }
      }
      current = current.parentElement;
    }

    console.warn('Could not find log-streamer controller in DOM hierarchy');
    return null;
  }

  #showMessage(message, type) {
    // Find message element from log streamer if available
    const messageEl = this.logStreamerController?.messageTarget;
    if (messageEl) {
      const className = type === "error" ? "error-message" : "success-message";
      messageEl.innerHTML = `<span class="${className}">${message}</span>`;
      setTimeout(() => {
        messageEl.innerHTML = "";
      }, 3000);
    }
  }

  #csrfToken() {
    return document.querySelector('meta[name="csrf-token"]')?.content || "";
  }
}
