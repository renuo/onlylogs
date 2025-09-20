import { Controller } from "@hotwired/stimulus"

export default class TextSelectionController extends Controller {
  static targets = ["button", "filterInput", "logLines", "regexpMode"]

  connect() {
    this.boundHandleTextSelection = this.handleTextSelection.bind(this)
    this.boundHandleDocumentClick = this.handleDocumentClick.bind(this)
    this.boundHandleSelectionChange = this.handleSelectionChange.bind(this)
    
    // Only listen for text selection on the log lines, not the toolbar
    this.logLinesTarget.addEventListener('mouseup', this.boundHandleTextSelection)
    document.addEventListener('click', this.boundHandleDocumentClick)
    document.addEventListener('selectionchange', this.boundHandleSelectionChange)
  }

  disconnect() {
    this.logLinesTarget.removeEventListener('mouseup', this.boundHandleTextSelection)
    document.removeEventListener('click', this.boundHandleDocumentClick)
    document.removeEventListener('selectionchange', this.boundHandleSelectionChange)
  }

  handleTextSelection(event) {
    const selection = window.getSelection()
    const selectedText = selection.toString().trim()
    
    // Check if there's actually a text selection
    if (selectedText.length > 0 && selection.rangeCount > 0) {
      this.showButton(event, selectedText)
    } else {
      this.hideButton()
    }
  }

  showButton(event, selectedText) {
    if (!this.buttonTarget) {
      return
    }
    
    const containerRect = this.element.getBoundingClientRect()
    
    // Position button below mouse cursor
    const left = event.clientX - containerRect.left - 40 // Roughly center the button
    const top = event.clientY - containerRect.top + 10
    
    this.buttonTarget.style.left = Math.max(0, left) + 'px'
    this.buttonTarget.style.top = Math.max(0, top) + 'px'
    this.buttonTarget.style.display = 'block'
    
    // Store selected text for search
    this.selectedText = selectedText
  }

  hideButton() {
    this.buttonTarget.style.display = 'none'
    this.selectedText = null
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
      if (thisthis.regexpModeTarget.checked) {
        this.regexpModeTarget.checked = false
        this.regexpModeTarget.dispatchEvent(new Event('change', { bubbles: true }))
      }
      
      this.filterInputTarget.value = this.selectedText
      this.filterInputTarget.dispatchEvent(new Event('input', { bubbles: true }))
      this.hideButton()
      window.getSelection().removeAllRanges()
    }
  }
}
