import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["startInput", "endInput", "startOutput", "endOutput"]

  connect() {
    this.update()
  }

  update(event) {
    let start = Number(this.startInputTarget.value)
    let end = Number(this.endInputTarget.value)

    if (start > end) {
      if (event?.target === this.startInputTarget) {
        end = start
        this.endInputTarget.value = end
      } else {
        start = end
        this.startInputTarget.value = start
      }
    }

    const min = Number(this.startInputTarget.min)
    const max = Number(this.startInputTarget.max)
    const startPercent = ((start - min) / (max - min)) * 100
    const endPercent = ((end - min) / (max - min)) * 100

    this.element.style.setProperty("--range-start-percent", `${startPercent}%`)
    this.element.style.setProperty("--range-end-percent", `${endPercent}%`)

    this.startOutputTarget.textContent = start
    this.endOutputTarget.textContent = end

    // Only dispatch event when user actually changes the input (not on initial connect)
    if (event) {
      this.element.dispatchEvent(new CustomEvent("range:update", { detail: { start, end } }))
    }
  }
}
