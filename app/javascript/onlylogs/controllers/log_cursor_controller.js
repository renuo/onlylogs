import { Controller } from "@hotwired/stimulus"

// A keyboard cursor over the log lines. Clusterize only keeps a window of the rows
// in the DOM, so the cursor is an index into all rows, repainted whenever the
// window is re-rendered. Left/right select words of the cursor line as a real text
// selection, so the "Search" popup of the text-selection controller picks them up.
export default class LogCursorController extends Controller {
  static targets = ["lines"]

  connect() {
    this.index = null
    this.#resetWords()
    this.observer = new MutationObserver(() => this.#paint())
    this.observer.observe(this.#content, { childList: true })
  }

  disconnect() {
    this.observer.disconnect()
  }

  focus(event) {
    event?.preventDefault()
    this.#content.focus({ preventScroll: true })
    this.activate()
  }

  activate() {
    if (this.index === null) this.index = this.#defaultIndex()
    this.#paint()
  }

  // The rows were thrown away (new query, new mode): an index into them means nothing now.
  reset() {
    this.index = null
    this.#resetWords()
    this.#paint()
  }

  placeAt({ detail: { row } }) {
    const index = this.#indexOf(row)
    if (index === null) return

    this.index = index
    this.#resetWords()
    this.#paint()
  }

  pointAt(event) {
    const row = this.#rowFor(event.target)
    if (row) this.placeAt({ detail: { row } })
  }

  navigate(event) {
    if (event.metaKey || event.ctrlKey || event.altKey) return

    const handled = this.#handleKey(event)
    if (handled !== false) event.preventDefault()
  }

  #handleKey(event) {
    switch (event.key) {
      case "ArrowDown": case "j": return this.#moveBy(1)
      case "ArrowUp": case "k": return this.#moveBy(-1)
      case "PageDown": return this.#moveBy(this.#pageSize())
      case "PageUp": return this.#moveBy(-this.#pageSize())
      case "Home": case "g": return this.#moveTo(0)
      case "End": case "G": return this.#moveTo(this.#rowsAmount - 1)
      case "ArrowRight": return this.#selectWord(1, event.shiftKey)
      case "ArrowLeft": return this.#selectWord(-1, event.shiftKey)
      case "Enter": case "o": return this.#open()
      case "y": return this.#copyLine()
      case "Escape": return this.#escape()
      default: return false
    }
  }

  #moveBy(delta) {
    if (this.index === null) return this.activate()
    this.#moveTo(this.index + delta)
  }

  #moveTo(index) {
    if (this.#rowsAmount === 0) return

    this.index = Math.min(Math.max(index, 0), this.#rowsAmount - 1)
    this.#resetWords()
    window.getSelection().removeAllRanges()
    this.dispatch("move")
    this.#reveal()
    this.#paint()

    // Long lines hide their match past the right edge; keep it in view.
    const match = this.#currentRow()?.querySelector("mark.onlylogs-match")
    if (match) this.#revealHorizontally(match)
  }

  // Enter acts on what is in front of you: the selected text if there is some,
  // otherwise the line itself.
  #open() {
    if (this.#hasSelectionInLines()) {
      this.dispatch("search")
      return
    }

    this.#currentRow()?.querySelector(".onlylogs-expand-btn")?.click()
  }

  #copyLine() {
    const row = this.#currentRow()
    if (!row) return

    navigator.clipboard?.writeText(this.#textElement(row).textContent)
    row.classList.remove("onlylogs-line-copied")
    void row.offsetWidth
    row.classList.add("onlylogs-line-copied")
  }

  #escape() {
    if (this.#hasSelectionInLines()) {
      window.getSelection().removeAllRanges()
      this.#resetWords()
      return
    }

    this.#content.blur()
  }

  // Words are what a log line is searched by: request ids, paths, status codes.
  // Quotes, brackets and "=" separate them, so `status=500` offers `500` on its own.
  #selectWord(direction, extend) {
    const row = this.#currentRow()
    if (!row) return this.activate()

    const element = this.#textElement(row)
    const words = [...element.textContent.matchAll(/[^\s"'=,;()[\]{}<>|]+/g)]
      .map(match => [match.index, match.index + match[0].length])
    if (words.length === 0) return

    const current = this.focusWord ?? (direction > 0 ? -1 : words.length)
    this.focusWord = Math.min(Math.max(current + direction, 0), words.length - 1)
    if (!extend || this.anchorWord === null) this.anchorWord = this.focusWord

    const first = words[Math.min(this.anchorWord, this.focusWord)]
    const last = words[Math.max(this.anchorWord, this.focusWord)]
    const range = this.#rangeFor(element, first[0], last[1])

    const selection = window.getSelection()
    selection.removeAllRanges()
    selection.addRange(range)
    this.#revealHorizontally(range)
    this.dispatch("select")
  }

  #rangeFor(element, start, end) {
    const range = document.createRange()
    const walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT)
    let offset = 0

    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      const length = node.textContent.length
      if (start >= offset && start <= offset + length) range.setStart(node, start - offset)
      if (end >= offset && end <= offset + length) {
        range.setEnd(node, end - offset)
        break
      }
      offset += length
    }

    return range
  }

  #resetWords() {
    this.anchorWord = null
    this.focusWord = null
  }

  #hasSelectionInLines() {
    const selection = window.getSelection()
    return selection.toString().trim() !== "" && this.linesTarget.contains(selection.anchorNode)
  }

  // Keeps two lines of context around the cursor, like an editor does.
  #reveal() {
    const lines = this.linesTarget
    const row = this.#currentRow()

    if (!row) {
      lines.scrollTop = this.index * this.#rowHeight() - lines.clientHeight / 2
      return
    }

    const rowRect = row.getBoundingClientRect()
    const top = lines.getBoundingClientRect().top
    const margin = rowRect.height * 2

    if (rowRect.top < top + margin) {
      lines.scrollTop -= top + margin - rowRect.top
    } else if (rowRect.bottom > top + lines.clientHeight - margin) {
      lines.scrollTop += rowRect.bottom - (top + lines.clientHeight - margin)
    }
  }

  #revealHorizontally(range) {
    const lines = this.linesTarget
    const rect = range.getBoundingClientRect()
    const left = lines.getBoundingClientRect().left

    if (rect.left < left) {
      lines.scrollLeft -= left - rect.left + 20
    } else if (rect.right > left + lines.clientWidth) {
      lines.scrollLeft += rect.right - (left + lines.clientWidth) + 20
    }
  }

  #paint() {
    this.#content.querySelector(".onlylogs-cursor-line")?.classList.remove("onlylogs-cursor-line")
    if (this.index === null) return

    if (this.index >= this.#rowsAmount) {
      this.index = null
      return
    }

    this.#currentRow()?.classList.add("onlylogs-cursor-line")
  }

  // Following a live tail you are looking at its end; anywhere else at the top of the pane.
  #defaultIndex() {
    if (this.#rowsAmount === 0) return null

    const lines = this.linesTarget
    if (lines.scrollTop + lines.clientHeight >= lines.scrollHeight - 2) return this.#rowsAmount - 1

    const top = lines.getBoundingClientRect().top
    const firstVisible = this.#renderedRows().find(row => row.getBoundingClientRect().top >= top)
    return firstVisible ? this.#indexOf(firstVisible) : 0
  }

  #pageSize() {
    return Math.max(1, Math.floor(this.linesTarget.clientHeight / this.#rowHeight()) - 2)
  }

  #rowHeight() {
    return this.#clusterize?.options.item_height || 16
  }

  #currentRow() {
    if (this.index === null) return null
    return this.#renderedRows()[this.index - this.#renderedStart] ?? null
  }

  #indexOf(row) {
    const position = this.#renderedRows().indexOf(row)
    return position === -1 ? null : this.#renderedStart + position
  }

  #rowFor(element) {
    let node = element
    while (node && node.parentElement !== this.#content) node = node.parentElement
    return node && !node.classList.contains("clusterize-extra-row") ? node : null
  }

  #renderedRows() {
    return [...this.#content.children].filter(row => !row.classList.contains("clusterize-extra-row"))
  }

  #textElement(row) {
    return row.matches("pre") ? row : row.querySelector("pre")
  }

  get #renderedStart() {
    return this.#clusterize?.getRenderedStart() ?? 0
  }

  get #rowsAmount() {
    return this.#clusterize?.getRowsAmount() ?? 0
  }

  get #clusterize() {
    return this.application.getControllerForElementAndIdentifier(this.element, "log-streamer")?.clusterize
  }

  get #content() {
    return this.linesTarget.querySelector(".clusterize-content")
  }
}
