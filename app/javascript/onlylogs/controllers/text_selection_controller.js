import { Controller } from "@hotwired/stimulus"

export default class TextSelectionController extends Controller {
  static targets = ["button", "filterInput", "logLines", "regexpMode"]

  connect() {
    this.boundHandleTextSelection = this.handleTextSelection.bind(this)
    this.boundHandleDocumentClick = this.handleDocumentClick.bind(this)
    this.boundHandleDocumentMouseDown = this.handleDocumentMouseDown.bind(this)
    this.boundHandleSelectionChange = this.handleSelectionChange.bind(this)
    this.boundHandleMouseDown = this.handleMouseDown.bind(this)
    this.boundPlaceButton = this.placeButton.bind(this)

    // Only listen for text selection on the log lines, not the toolbar
    this.logLinesTarget.addEventListener('mousedown', this.boundHandleMouseDown)
    this.logLinesTarget.addEventListener('mouseup', this.boundHandleTextSelection)
    this.logLinesTarget.addEventListener('scroll', this.boundPlaceButton)
    document.addEventListener('mousedown', this.boundHandleDocumentMouseDown)
    document.addEventListener('click', this.boundHandleDocumentClick)
    document.addEventListener('selectionchange', this.boundHandleSelectionChange)
  }

  disconnect() {
    this.logLinesTarget.removeEventListener('mousedown', this.boundHandleMouseDown)
    this.logLinesTarget.removeEventListener('mouseup', this.boundHandleTextSelection)
    this.logLinesTarget.removeEventListener('scroll', this.boundPlaceButton)
    document.removeEventListener('mousedown', this.boundHandleDocumentMouseDown)
    document.removeEventListener('click', this.boundHandleDocumentClick)
    document.removeEventListener('selectionchange', this.boundHandleSelectionChange)
  }

  handleMouseDown(event) {
    if (this.#onScrollbar(event)) return

    this.dispatch("start")
  }

  handleDocumentMouseDown(event) {
    if (this.buttonTarget.contains(event.target) || this.#onScrollbar(event)) return

    this.saved = null
  }

  handleTextSelection(event) {
    const selection = window.getSelection()
    const selectedText = selection.toString().trim()

    // Check if there's actually a text selection
    if (selectedText.length > 0 && selection.rangeCount > 0) {
      this.showButton(event.clientX, event.clientY, selectedText)
    } else {
      this.hideButton()
    }
  }

  // Bound to log-cursor:select, a selection made with the keyboard.
  showForSelection() {
    const selection = window.getSelection()
    const selectedText = selection.toString().trim()
    if (selectedText.length === 0 || selection.rangeCount === 0) return

    this.saved = null
    const rect = selection.getRangeAt(0).getBoundingClientRect()
    this.showButton(rect.left + 40, rect.bottom, selectedText)
  }

  showButton(clientX, clientY, selectedText) {
    if (!this.buttonTarget) {
      return
    }

    const containerRect = this.element.getBoundingClientRect()

    // Position button below mouse cursor
    this.buttonPosition = {
      left: clientX - containerRect.left - 40, // Roughly center the button
      top: clientY - containerRect.top + 10,
      scrollLeft: this.logLinesTarget.scrollLeft,
      scrollTop: this.logLinesTarget.scrollTop
    }

    // Store selected text for search
    this.selectedText = selectedText
    this.placeButton()
  }

  placeButton() {
    if (!this.buttonPosition || !this.selectedText) return

    const lines = this.logLinesTarget
    const left = this.buttonPosition.left - (lines.scrollLeft - this.buttonPosition.scrollLeft)
    const top = this.buttonPosition.top - (lines.scrollTop - this.buttonPosition.scrollTop)

    const linesTop = lines.getBoundingClientRect().top - this.element.getBoundingClientRect().top
    const visible = top >= linesTop && top <= linesTop + lines.clientHeight - this.buttonTarget.offsetHeight

    this.buttonTarget.style.left = Math.max(0, left) + 'px'
    this.buttonTarget.style.top = Math.max(0, top) + 'px'
    this.buttonTarget.style.display = visible ? 'block' : 'none'
  }

  hideButton() {
    this.buttonTarget.style.display = 'none'
    this.selectedText = null
  }

  saveSelection({ detail: { start } }) {
    const selection = window.getSelection()
    if (!this.#selectionInLines(selection)) return

    const anchor = this.#positionOf(selection.anchorNode, selection.anchorOffset, start)
    const focus = this.#positionOf(selection.focusNode, selection.focusOffset, start)
    if (anchor && focus) this.saved = { anchor, focus }
  }

  restoreSelection({ detail: { start } }) {
    if (!this.saved) return

    const selection = window.getSelection()
    if (this.#selectionInLines(selection)) return

    const anchor = this.#pointIn(this.saved.anchor, start)
    const focus = this.#pointIn(this.saved.focus, start)
    if (!anchor || !focus) return

    selection.setBaseAndExtent(anchor.node, anchor.offset, focus.node, focus.offset)
    this.selectedText = selection.toString().trim()
    this.placeButton()
  }

  forgetSelection() {
    this.saved = null
    this.hideButton()
  }

  handleDocumentClick(event) {
    // Only hide if clicking outside the button and outside the log lines container
    if (!this.buttonTarget.contains(event.target) && !this.logLinesTarget.contains(event.target)) {
      this.hideButton()
    }
  }

  handleSelectionChange() {
    // Check if the current selection is still valid
    const selection = window.getSelection()
    const selectedText = selection.toString().trim()

    // If no text is selected, hide the button
    if (selectedText.length === 0 || selection.rangeCount === 0) {
      this.hideButton()
    }
  }

  searchSelectedText() {
    if (this.selectedText) {
      if (this.regexpModeTarget.checked) {
        this.regexpModeTarget.checked = false
        this.regexpModeTarget.dispatchEvent(new Event('change', { bubbles: true }))
      }

      this.filterInputTarget.value = this.selectedText
      this.filterInputTarget.dispatchEvent(new Event('input', { bubbles: true }))
      this.dispatch("search")
      this.hideButton()
      this.saved = null
      window.getSelection().removeAllRanges()
    }
  }

  #onScrollbar(event) {
    const lines = this.logLinesTarget
    if (event.target !== lines) return false

    const rect = lines.getBoundingClientRect()
    return event.clientX - rect.left >= lines.clientWidth || event.clientY - rect.top >= lines.clientHeight
  }

  #selectionInLines(selection) {
    return !selection.isCollapsed && this.#content.contains(selection.anchorNode) && this.#content.contains(selection.focusNode)
  }

  #positionOf(node, offset, start) {
    const row = this.#rowFor(node)
    if (!row) return null

    const range = document.createRange()
    range.setStart(row, 0)
    range.setEnd(node, offset)
    return { row: start + this.#renderedRows().indexOf(row), offset: range.toString().length }
  }

  #pointIn(position, start) {
    const row = this.#renderedRows()[position.row - start]
    if (!row) return null

    const walker = document.createTreeWalker(row, NodeFilter.SHOW_TEXT)
    let remaining = position.offset
    let last = null
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      if (remaining <= node.length) return { node, offset: remaining }
      remaining -= node.length
      last = node
    }
    return last ? { node: last, offset: last.length } : { node: row, offset: 0 }
  }

  #rowFor(node) {
    while (node && node.parentNode !== this.#content) node = node.parentNode
    return node && !node.classList.contains("clusterize-extra-row") ? node : null
  }

  #renderedRows() {
    return [...this.#content.children].filter(row => !row.classList.contains("clusterize-extra-row"))
  }

  get #content() {
    return this.logLinesTarget.querySelector(".clusterize-content")
  }
}
