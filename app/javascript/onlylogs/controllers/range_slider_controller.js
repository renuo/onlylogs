import { Controller } from "@hotwired/stimulus";

// Owns the presentation of the double range slider: clamping the two handles,
// painting the selected span, formatting the byte readout and widening the step
// as the selected range grows.
//
// It holds no state of its own - the inputs are the state. Whoever sets those
// values programmatically fires `range-slider:refresh` to have them repainted,
// and gets `range-slider:change` back when a user finishes dragging.
export default class RangeSliderController extends Controller {
  static targets = ["startInput", "endInput", "startOutput", "endOutput"];

  connect() {
    this.lastStep = null;
    this.refresh();
  }

  // Bound to input/change on both handles. Only `change` - the end of a drag -
  // is worth re-reading the file for.
  updateVisuals(event) {
    const { start, end } = this.#clampedValues();

    this.#paint(start, end);

    if (event?.type === "change") {
      this.#growStep(start, end);
      this.dispatch("change", { detail: { start, end } });
    }
  }

  // The values were set from outside; repaint without reporting a change.
  refresh() {
    const { start, end } = this.#clampedValues();
    this.#paint(start, end);
  }

  // Reads the handles, snapping to the ends and keeping start <= end, and
  // writes back whatever it had to correct.
  #clampedValues() {
    let start = Number(this.startInputTarget.value);
    let end = Number(this.endInputTarget.value);

    const sliderMax = Number(this.startInputTarget.max);
    const step = Number(this.startInputTarget.step);

    // Snap to 100% if close to max (within 2% or one step)
    const threshold = Math.max(sliderMax * 0.02, step);
    if (end > sliderMax - threshold) end = sliderMax;
    if (start > sliderMax - threshold) start = sliderMax;

    if (start > end) [start, end] = [end, start];

    this.startInputTarget.value = start;
    this.endInputTarget.value = end;

    return { start, end };
  }

  #paint(start, end) {
    const sliderMax = Number(this.startInputTarget.max);

    this.element.style.setProperty("--range-start-percent", `${(start / sliderMax) * 100}%`);
    this.element.style.setProperty("--range-end-percent", `${(end / sliderMax) * 100}%`);

    this.startOutputTarget.textContent = this.#formatBytes(start);
    this.endOutputTarget.textContent = this.#formatBytes(end);
  }

  // A narrow selection wants byte-level precision; a wide one would take
  // thousands of steps to cross at that resolution.
  #growStep(start, end) {
    const selectedBytes = Math.max(end - start, 1);
    const step = Math.max(1, 10 ** Math.ceil(Math.log10(selectedBytes / 200)));

    if (step === this.lastStep) return;

    this.lastStep = step;
    this.startInputTarget.step = step;
    this.endInputTarget.step = step;
  }

  #formatBytes(value) {
    const units = ['Bytes', 'KB', 'MB', 'GB', 'TB'];
    let size = Math.max(0, value);
    let unit = 0;

    while (size >= 1024 && unit < units.length - 1) {
      size /= 1024;
      unit += 1;
    }

    const rounded = unit === 0 ? size : Number(size.toFixed(1));

    return `${rounded} ${units[unit]}`;
  }
}
