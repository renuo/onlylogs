import { Controller } from "@hotwired/stimulus"

// Marks what the query matched on every rendered line. Clusterize only keeps a
// window of rows in the DOM and re-renders it from HTML strings, so the marks are
// re-applied whenever that window changes rather than baked into the rows.
// The query is re-compiled as a JavaScript RegExp; ripgrep syntax that JavaScript
// does not understand just leaves the lines unmarked.
export default class MatchHighlightController extends Controller {
  static targets = ["lines", "filterInput", "regexpMode", "caseInsensitive"]

  connect() {
    this.observer = new MutationObserver(() => this.highlight())
    this.observer.observe(this.#content, { childList: true })
  }

  disconnect() {
    this.observer.disconnect()
  }

  highlight() {
    const pattern = this.#pattern()
    if (!pattern) return

    this.#content.querySelectorAll(":scope > pre, :scope > div > pre").forEach(line => this.#mark(line, pattern))
  }

  #pattern() {
    const query = this.filterInputTarget.value.trim()
    if (query === "") return null

    const source = this.regexpModeTarget.checked ? query : query.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
    try {
      return new RegExp(source, this.caseInsensitiveTarget.checked ? "gi" : "g")
    } catch {
      return null
    }
  }

  // A match can span several text nodes (ANSI colour spans, file links), so each
  // one is wrapped piece by piece. Working backwards keeps the earlier offsets valid
  // while the text nodes are being split.
  #mark(line, pattern) {
    const matches = [...line.textContent.matchAll(pattern)].filter(match => match[0].length > 0)
    if (matches.length === 0) return

    const nodes = []
    const walker = document.createTreeWalker(line, NodeFilter.SHOW_TEXT)
    let offset = 0
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      nodes.push({ node, start: offset, end: offset + node.length })
      offset += node.length
    }

    for (const match of matches.reverse()) {
      const start = match.index
      const end = start + match[0].length

      for (const entry of [...nodes].reverse()) {
        if (entry.start >= end || entry.end <= start) continue

        const from = Math.max(start, entry.start) - entry.start
        const to = Math.min(end, entry.end) - entry.start

        if (to < entry.node.length) entry.node.splitText(to)
        const piece = from > 0 ? entry.node.splitText(from) : entry.node
        const mark = document.createElement("mark")
        mark.className = "onlylogs-match"
        piece.replaceWith(mark)
        mark.append(piece)

        entry.end = entry.start + from
      }
    }
  }

  get #content() {
    return this.linesTarget.querySelector(".clusterize-content")
  }
}
