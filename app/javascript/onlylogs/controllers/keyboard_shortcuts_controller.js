import { Controller } from "@hotwired/stimulus"

export default class KeyboardShortcutsController extends Controller {
  static targets = ["liveMode", "autoscroll"]

  connect() {
    this.boundHandleKeydown = this.handleKeydown.bind(this)
    document.addEventListener('keydown', this.boundHandleKeydown)
  }

  disconnect() {
    document.removeEventListener('keydown', this.boundHandleKeydown)
  }

  handleKeydown(event) {
    // Only handle shortcuts when not typing in input fields
    if (event.target.tagName === 'INPUT' || event.target.tagName === 'TEXTAREA') {
      return
    }

    switch (event.key.toLowerCase()) {
      case 'l':
        event.preventDefault()
        this.toggleLiveMode()
        break
      case 'a':
        event.preventDefault()
        this.toggleAutoscroll()
        break
    }
  }

  toggleLiveMode() {
    if (this.hasLiveModeTarget) {
      this.liveModeTarget.checked = !this.liveModeTarget.checked
      this.liveModeTarget.dispatchEvent(new Event('change', { bubbles: true }))
    }
  }

  toggleAutoscroll() {
    if (this.hasAutoscrollTarget) {
      this.autoscrollTarget.checked = !this.autoscrollTarget.checked
      this.autoscrollTarget.dispatchEvent(new Event('change', { bubbles: true }))
    }
  }
}
