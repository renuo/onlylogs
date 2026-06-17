import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["startInput", "endInput", "startOutput", "endOutput"]

  connect() {
    this.updateVisuals()
  }

  updateVisuals(event) {
    let start = Number(this.startInputTarget.value)
    let end = Number(this.endInputTarget.value)

    // Enforce start <= end
    if (start > end) {
      if (event?.target === this.startInputTarget) {
        this.endInputTarget.value = start
      } else {
        this.startInputTarget.value = end
      }
    }

    // Update visuals and dispatch event on change
    this.#updateDisplay(Math.min(start, end), Math.max(start, end))
    if (event?.type === 'change') {
      this.element.dispatchEvent(new CustomEvent("range:update", { detail: { start, end } }))
    }
  }

  #updateDisplay(start, end) {
    const min = Number(this.startInputTarget.min)
    const range = Number(this.startInputTarget.max) - min

    this.element.style.setProperty("--range-start-percent", `${((start - min) / range) * 100}%`)
    this.element.style.setProperty("--range-end-percent", `${((end - min) / range) * 100}%`)

    this.startOutputTarget.textContent = start
    this.endOutputTarget.textContent = end
  }
}
