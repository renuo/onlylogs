import { Controller } from "@hotwired/stimulus"

export default class KeyboardShortcutsController extends Controller {
  static targets = ["liveButton", "searchButton", "autoscroll"]

  connect() {
    this.boundHandleKeydown = this.handleKeydown.bind(this)
    document.addEventListener('keydown', this.boundHandleKeydown)
  }

  disconnect() {
    document.removeEventListener('keydown', this.boundHandleKeydown)
  }

  handleKeydown(event) {
    // These are bare single-key shortcuts. Any modifier means the keystroke belongs
    // to the browser or the OS (cmd+L, cmd+A, cmd+S) and must pass straight through.
    if (event.metaKey || event.ctrlKey || event.altKey) {
      return
    }

    // Only handle shortcuts when not typing in input fields
    if (event.target.tagName === 'INPUT' || event.target.tagName === 'TEXTAREA' || event.target.isContentEditable) {
      return
    }

    switch (event.key.toLowerCase()) {
      case 'l':
        event.preventDefault()
        if (this.hasLiveButtonTarget) this.liveButtonTarget.click()
        break
      case 's':
        event.preventDefault()
        if (this.hasSearchButtonTarget) this.searchButtonTarget.click()
        break
      case 'a':
        event.preventDefault()
        this.toggleAutoscroll()
        break
    }
  }

  toggleAutoscroll() {
    // Autoscroll only exists while live; ignore the shortcut when it is not on screen.
    if (this.hasAutoscrollTarget && this.autoscrollTarget.offsetParent !== null) {
      this.autoscrollTarget.checked = !this.autoscrollTarget.checked
      this.autoscrollTarget.dispatchEvent(new Event('change', { bubbles: true }))
    }
  }
}
