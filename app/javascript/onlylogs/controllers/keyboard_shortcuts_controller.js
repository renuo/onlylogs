import { Controller } from "@hotwired/stimulus"

// Holding the modifier shows a badge with a letter on every control marked with
// `data-onlylogs-shortcut`; modifier + letter triggers it from anywhere, also while
// typing a query. The modifier is Control on macOS and Alt elsewhere: neither types
// characters there (Option does on a Mac - `@`, `|`, `[` on a Swiss layout), and
// Ctrl+Alt is AltGr on Windows, which is why the other one must not be held.
// Host apps can mark their own controls with the same attribute.
export default class KeyboardShortcutsController extends Controller {
  static targets = ["filterInput", "dialog"]
  static values = { modifier: { type: String, default: "alt" } }

  connect() {
    this.boundHandleKeydown = this.handleKeydown.bind(this)
    this.boundHandleKeyup = this.handleKeyup.bind(this)
    this.boundHideHints = this.hideHints.bind(this)
    document.addEventListener("keydown", this.boundHandleKeydown)
    document.addEventListener("keyup", this.boundHandleKeyup)
    window.addEventListener("blur", this.boundHideHints)

    this.#hosts().forEach(host => {
      this.#actionable(host).setAttribute("aria-keyshortcuts", `${this.#modifierKey}+${host.dataset.onlylogsShortcut.toUpperCase()}`)
    })
  }

  disconnect() {
    document.removeEventListener("keydown", this.boundHandleKeydown)
    document.removeEventListener("keyup", this.boundHandleKeyup)
    window.removeEventListener("blur", this.boundHideHints)
    this.hideHints()
  }

  handleKeydown(event) {
    if (event.key === this.#modifierKey) {
      if (!event.repeat && this.#modifierHeld(event)) this.#scheduleHints()
      return
    }

    // Modifier + Tab and the like are someone else's; only a modifier held on its own shows hints.
    clearTimeout(this.hintTimer)

    if (this.#modifierHeld(event)) {
      this.#handleChord(event)
    } else if (!event.metaKey && !event.ctrlKey && !event.altKey && !event.defaultPrevented) {
      this.#handleBareKey(event)
    }
  }

  handleKeyup(event) {
    if (event.key !== this.#modifierKey) return

    // Releasing a lone Alt opens the menu bar in Firefox on Windows and Linux.
    if (this.hintsShown || this.chordUsed) event.preventDefault()
    this.chordUsed = false
    this.hideHints()
  }

  hideHints() {
    clearTimeout(this.hintTimer)
    this.hintsShown = false
    document.documentElement.classList.remove("onlylogs-shortcuts-visible")
  }

  openHelp() {
    this.hideHints()
    this.dialogTarget.showModal()
  }

  #scheduleHints() {
    clearTimeout(this.hintTimer)
    this.hintTimer = setTimeout(() => {
      this.hintsShown = true
      document.documentElement.classList.add("onlylogs-shortcuts-visible")
    }, 250)
  }

  #handleChord(event) {
    if (event.shiftKey || this.dialogTarget.open) return

    const letter = this.#letterFor(event)
    const host = this.#hosts().find(host => host.dataset.onlylogsShortcut === letter && this.#visible(host))
    if (!host) return

    event.preventDefault()
    this.chordUsed = true
    this.#trigger(this.#actionable(host))
  }

  #handleBareKey(event) {
    if (this.#typing(event.target) || this.dialogTarget.open) return

    switch (event.key) {
      case "/":
        event.preventDefault()
        this.#trigger(this.filterInputTarget)
        break
      case "?":
        event.preventDefault()
        this.openHelp()
        break
      case "ArrowDown":
      case "j":
        event.preventDefault()
        this.dispatch("lines")
        break
    }
  }

  #trigger(element) {
    if (element.matches("input[type=text], input[type=search], textarea")) {
      element.focus()
      element.select()
    } else if (element.matches("select")) {
      element.focus()
      try { element.showPicker() } catch { /* not supported: focused is enough */ }
    } else if (element.matches("input[type=range]")) {
      element.focus()
    } else {
      element.click()
    }
  }

  // The badge sits on a wrapper when the control itself cannot carry one (inputs, selects).
  #actionable(host) {
    if (host.matches("input, select, button, textarea")) return host
    return host.querySelector("input, select, button, textarea") ?? host
  }

  // event.key is the character the layout produced; with Alt on Windows that is the
  // letter itself, but a Mac turns some combinations into symbols, so fall back to
  // the physical key.
  #letterFor(event) {
    if (/^[a-z0-9.]$/i.test(event.key)) return event.key.toLowerCase()

    const [, letter] = event.code.match(/^(?:Key|Digit)(\w)$/) ?? []
    if (letter) return letter.toLowerCase()
    return event.code === "Period" ? "." : null
  }

  #modifierHeld(event) {
    if (event.metaKey) return false
    return this.modifierValue === "control" ? event.ctrlKey && !event.altKey : event.altKey && !event.ctrlKey
  }

  #typing(element) {
    return element.matches?.("input, textarea, select") || element.isContentEditable
  }

  #visible(element) {
    return element.getClientRects().length > 0
  }

  #hosts() {
    return [...document.querySelectorAll("[data-onlylogs-shortcut]")]
  }

  get #modifierKey() {
    return this.modifierValue === "control" ? "Control" : "Alt"
  }
}
