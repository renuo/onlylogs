import { Controller } from "@hotwired/stimulus";
import { createConsumer } from "@rails/actioncable";

export default class LogStreamerController extends Controller {
  static values = {
    filePath: { type: String },
    autoScroll: { type: Boolean, default: true },
    filter: { type: String, default: '' },
    mode: { type: String, default: 'live' },
    regexpMode: { type: Boolean, default: false },
    fileSize: { type: Number, default: 0 },
    startPosition: { type: Number, default: 0 },
    endPosition: { type: Number, default: 0 }
  };

  static targets = ["logLines", "filterInput", "results", "liveButton", "searchButton", "searchWholeFileButton", "message", "regexpMode", "websocketStatus", "stopButton", "clearButton", "autoscroll", "rangeSliderContainer", "startSlider", "endSlider", "searchPlaceholder"];

  // When the current live query started, so "0 matches" can say since when.
  #liveFilterStartedAt = null;

  connect() {
    this.consumer = createConsumer();

    this.subscription = null;
    this.isRunning = false;
    this.reconnectTimeout = null;
    this.isSearchFinished = true;
    this.historyUpdateTimeout = null;
    this.contextLineHighlighted = false;

    // Initialize clusterize
    this.clusterize = null;
    this.#initializeClusterize();

    this.#updateWebsocketStatus('disconnected');

    // Restore state from URL params if present
    this.#restoreStateFromUrl();

    // Listen for browser back/forward button clicks
    window.addEventListener('popstate', () => {
      this.#restoreStateFromUrl();
      this.reconnectWithNewMode();
    });

    this.start();
    this.scroll();
  }

  disconnect() {
    this.stop();

    // Clear any pending reconnect timeout
    if (this.reconnectTimeout) {
      clearTimeout(this.reconnectTimeout);
      this.reconnectTimeout = null;
    }

    // Destroy clusterize instance
    if (this.clusterize) {
      this.clusterize.destroy();
      this.clusterize = null;
    }
  }

  start() {
    if (this.isRunning) {
      return;
    }

    this.isRunning = true;
    this.#createSubscription();
  }

  stop() {
    if (!this.isRunning) {
      return;
    }

    this.isRunning = false;

    if (this.subscription) {
      this.stopSearch();
      this.subscription.unsubscribe();
      this.subscription = null;
    }
  }

  reset() {
    this.stop();
    this.clear();
    this.#reinitializeClusterize();
    this.start();
  }

  clear() {
    this.clusterize.clear();
    this.#updateResultsDisplay();
  }

  toggleAutoScroll() {
    this.autoScrollValue = !this.autoScrollValue;
    this.#updateUrlParam('autoscroll', this.autoScrollValue ? null : 'false');
    this.scroll();
  }

  pauseForSelection() {
    // Triggered by TextSelectionController#handleMouseDown via text-selection:start event.
    // Stopping autoscroll is enough to keep the text still under the cursor; the mode
    // is the user's to change, so selecting text must never switch it.
    if (this.autoScrollValue) {
      this.autoScrollValue = false;
      this.autoscrollTarget.checked = false;
      this.#updateUrlParam('autoscroll', 'false');
    }
  }

  toggleRegexpMode() {
    this.regexpModeValue = this.regexpModeTarget.checked;
    this.#updateUrlParam('regexp_mode', this.regexpModeValue ? 'true' : null);
    // If we have a filter applied, reconnect to apply the new regexp mode
    if (this.filterInputTarget.value && this.filterInputTarget.value.trim() !== '') {
      this.reconnectWithNewMode();
    }
  }

  switchToLive() {
    if (this.isLiveMode()) return;

    this.#clearHighlighting();
    this.#setMode('live');
    this.clear();
    this.#setRange(0, this.fileSizeValue);
    this.#updateUrlParams({ start_position: null, end_position: null, byte_offset: null });
    this.reconnectWithNewMode();
  }

  switchToSearch() {
    if (!this.isLiveMode()) return;

    this.#setMode('static');
    this.reconnectWithNewMode();
  }

  // Bound only to the "Search whole file" button, which is shown while tailing.
  // Leaves live mode: runs what is already typed against the file instead of
  // waiting for a matching line to arrive.
  searchWholeFile() {
    this.#clearHighlighting();
    this.#setMode('static');
    this.#setRange(0, this.fileSizeValue);
    this.#updateUrlParams({ start_position: null, end_position: null, byte_offset: null });
    this.reconnectWithNewMode();
    this.filterInputTarget.focus();
  }

  applyFilter() {
    const filterValue = this.filterInputTarget.value;

    // Clear byte_offset and highlighting when applying a new filter
    this.#clearHighlighting();
    this.#updateUrlParam('byte_offset', null);

    // Update visual state
    this.updateStopButtonVisibility();
    this.#updateUrlParam('filter', filterValue || null);
    this.#liveFilterStartedAt = this.isLiveMode() ? new Date() : null;
    this.#updateResultsDisplay();

    // Use the global debounced reconnection (300ms delay)
    this.reconnectWithNewMode();
  }

  isLiveMode() {
    return this.modeValue === 'live';
  }

  // The only writer of modeValue. Everything that changes the mode goes through
  // here so the switch, the URL and the toolbar layout can never disagree.
  #setMode(mode) {
    this.modeValue = mode;
    this.#updateUrlParam('mode', mode === 'live' ? null : 'static');
    this.#liveFilterStartedAt = mode === 'live' ? new Date() : null;
    this.#syncModeControls();
  }

  #syncModeControls() {
    const live = this.isLiveMode();
    this.#syncSearchPlaceholder();

    if (this.hasLiveButtonTarget) {
      this.liveButtonTarget.setAttribute('aria-pressed', live);
    }
    if (this.hasSearchButtonTarget) {
      this.searchButtonTarget.setAttribute('aria-pressed', !live);
    }

    this.filterInputTarget.placeholder = live ? 'follow lines matching…' : 'search the whole file…';
    this.#updateResultsDisplay();
  }

  scroll() {
    if (this.autoScrollValue) {
      this.logLinesTarget.scrollTop = this.logLinesTarget.scrollHeight;
    }
  }

  reconnectWithNewMode() {
    // Clear any existing reconnect timeout
    if (this.reconnectTimeout) {
      clearTimeout(this.reconnectTimeout);
    }

    // Debounce reconnection to avoid multiple rapid reconnections
    this.reconnectTimeout = setTimeout(() => {
      // Soft disconnect: unsubscribe without sending stop_watcher message.
      // In live mode, we don't want "Search stopped" on every filter change.
      if (this.subscription) {
        this.subscription.unsubscribe();
        this.subscription = null;
      }
      this.isRunning = false;
      this.clear();
      this.#reinitializeClusterize();
      this.start();
      this.reconnectTimeout = null;
    }, 600);
  }

  // Clears the text only. The mode and the range belong to their own controls,
  // so an × on a text field must not quietly reach over and change them.
  clearFilter() {
    this.filterInputTarget.value = '';
    this.#clearHighlighting();
    this.updateStopButtonVisibility();
    this.#updateUrlParams({ filter: null, byte_offset: null });
    this.#liveFilterStartedAt = this.isLiveMode() ? new Date() : null;
    this.reconnectWithNewMode();
    this.filterInputTarget.focus();
  }

  stopSearch() {
    console.log("stop search");
    this.subscription.perform('stop_watcher');
  }


  handleExpandClick(e) {
    const btn = e.target.closest('.onlylogs-expand-btn');
    if (!btn) return;

    const byteOffset = parseInt(btn.getAttribute('data-byte-offset'));
    if (!byteOffset) return;

    const contextBytes = 10000;
    const start = Math.max(0, byteOffset - contextBytes);
    const end = Math.min(this.fileSizeValue, byteOffset + contextBytes);

    // Context around a line can only be read unfiltered, so the query is dropped
    // here on purpose - and the mode switch is now visible on the toolbar.
    this.filterInputTarget.value = '';
    this.#setMode('static');

    // Update URL with byte_offset and range
    this.#updateUrlParam('byte_offset', byteOffset);
    this.#updateUrlParam('filter', null);
    this.#updateUrlParam('start_position', start);
    this.#updateUrlParam('end_position', end);

    this.contextLineHighlighted = false;
    this.#setRange(start, end);
    this.reconnectWithNewMode();
  }

  clearLogs() {
    this.clear();
    this.#hideMessage();
  }

  #highlightContextLine() {
    const target = Number(new URLSearchParams(window.location.search).get('byte_offset'));
    if (Number.isNaN(target)) return;

    this.#applyContextLineHighlight(target);

    const closestPre = this.#closestPreByByteOffset(target);

    if (closestPre) {
      this.#scrollVerticallyToCenter(closestPre);
    }
  }

  #scrollVerticallyToCenter(element) {
    this.#rowElement(element).scrollIntoView({ behavior: 'smooth', block: 'center' });
  }

  #clearHighlighting() {
    this.contextLineHighlighted = false;
    this.logLinesTarget.querySelectorAll('.highlighted-context-line').forEach(el => {
      el.classList.remove('highlighted-context-line');
    });
  }

  #closestPreByByteOffset(target) {
    return [...this.logLinesTarget.querySelectorAll('pre[data-byte-offset]')]
      .reduce((closest, pre) => {
        const byteOffset = Number(pre.dataset.byteOffset);
        if (Number.isNaN(byteOffset)) return closest;

        const distance = Math.abs(byteOffset - target);
        return !closest || distance < closest.distance ? { pre, distance } : closest;
      }, null)?.pre;
  }

  #applyContextLineHighlight(target) {
    const closestPre = this.#closestPreByByteOffset(target);

    if (!closestPre) return;

    const row = this.#rowElement(closestPre);

    // Highlight target line ± 3 lines (7 lines total)
    const linesToHighlight = [];
    let current = row;

    // Add 3 previous lines
    for (let i = 0; i < 3; i++) {
      if (current.previousElementSibling) {
        current = current.previousElementSibling;
        linesToHighlight.unshift(current);
      }
    }

    // Add target line
    linesToHighlight.push(row);

    // Add 3 next lines
    current = row;
    for (let i = 0; i < 3; i++) {
      if (current.nextElementSibling) {
        current = current.nextElementSibling;
        linesToHighlight.push(current);
      }
    }

    linesToHighlight.forEach(line => line.classList.add('highlighted-context-line'));
    this.contextLineHighlighted = true;
  }

  // A row is either a bare <pre> or an expand-button wrapper <div> directly
  // under the clusterize content area. Walk up to that top-level element so the
  // highlight covers the whole line, including the "+" toggle.
  #rowElement(element) {
    let node = element;
    while (node.parentElement && !node.parentElement.classList.contains('clusterize-content')) {
      node = node.parentElement;
    }
    return node;
  }

  updateStopButtonVisibility() {
    const shouldShow = this.modeValue === 'static' && this.subscription && this.isRunning && !this.isSearchFinished;
    this.stopButtonTarget.style.display = shouldShow ? 'inline-block' : 'none';
  }

  #setRange(start, end) {
    this.startSliderTarget.value = start;
    this.endSliderTarget.value = end;

    if (this.hasRangeSliderContainerTarget) {
      this.rangeSliderContainerTarget.dispatchEvent(new CustomEvent('range-slider:refresh'));
    }
  }

  // The slider only exists in search mode, and it only ever changes the range.
  // It used to flip the mode as a side effect, which is how people ended up in
  // live mode without having asked for it.
  handleRangeUpdate(event) {
    const { start, end } = event?.detail ?? this.#currentRange();
    const isDefaultRange = this.#isFullRange(start, end);

    this.#updateUrlParams({
      start_position: isDefaultRange ? null : start,
      end_position: isDefaultRange ? null : end
    });

    // Clear byte_offset and highlighting if it falls outside the new range
    const params = new URLSearchParams(window.location.search);
    const byteOffset = parseInt(params.get('byte_offset'));
    if (!Number.isNaN(byteOffset) && (byteOffset < start || byteOffset > end)) {
      this.#updateUrlParam('byte_offset', null);
      this.#clearHighlighting();
    }

    this.reconnectWithNewMode();
  }

  resetRange() {
    this.#setRange(0, this.fileSizeValue);
    this.handleRangeUpdate();
  }

  #restoreStateFromUrl() {
    const params = new URLSearchParams(window.location.search);

    // Restore filter (clear if not present in URL)
    const filter = params.get('filter') || '';
    this.filterInputTarget.value = filter;

    // Restore autoscroll
    const autoscroll = params.get('autoscroll');
    if (autoscroll === 'false') {
      this.autoScrollValue = false;
      this.autoscrollTarget.checked = false;
    } else {
      this.autoScrollValue = true;
      this.autoscrollTarget.checked = true;
    }

    // Restore regexp mode
    const regexpMode = params.get('regexp_mode');
    if (regexpMode === 'true') {
      this.regexpModeValue = true;
      this.regexpModeTarget.checked = true;
    } else {
      this.regexpModeValue = false;
      this.regexpModeTarget.checked = false;
    }

    // Restore range
    const startParam = params.get('start_position');
    const endParam = params.get('end_position');

    const start = startParam ? parseInt(startParam) : 0;
    const end = endParam ? parseInt(endParam) : this.fileSizeValue;
    this.#setRange(start, end);

    // Calculate mode: check mode param, default to live
    this.modeValue = params.get('mode') === 'static' ? 'static' : 'live';
    this.#liveFilterStartedAt = this.isLiveMode() ? new Date() : null;
    this.#syncModeControls();
  }

  /**
   * Create ActionCable subscription
   */
  #createSubscription() {
    this.subscription = this.consumer.subscriptions.create("Onlylogs::LogsChannel", {
      connected: () => {
        this.#handleConnected();
      },

      disconnected: () => {
        this.#handleDisconnected();
      },

      rejected: () => {
        this.#handleRejected();
      },

      received: (data) => {
        if (data.action === 'append_logs') {
          this.isSearchFinished = this.isLiveMode();
          this.#handleLogLines(data.lines);
        } else if (data.action === 'message') {
          this.#handleMessage(data.content);
        } else if (data.action === 'finish') {
          this.#handleFinish(data.content);
        } else if (data.action === 'error') {
          this.#handleError(data.content);
        }
      }
    });
  }

  /**
   * Handle successful connection
   */
  // An empty query matches every line, so running it would stream the whole file
  // back. Nothing is searched until something is typed.
  #isIdleSearch() {
    if (this.isLiveMode()) return false;
    if (this.filterInputTarget.value.trim() !== "") return false;

    // A bounded range - the slider, or the window "show around this line" opens -
    // is a read of a known slice, not an unbounded scan, so it still runs.
    const start = parseInt(this.startSliderTarget.value);
    const end = parseInt(this.endSliderTarget.value);
    return this.#isFullRange(start, end);
  }

  #syncSearchPlaceholder() {
    if (!this.hasSearchPlaceholderTarget) return;
    this.searchPlaceholderTarget.hidden = !this.#isIdleSearch();
  }

  #setConnectionState(status) {
    this.#updateWebsocketStatus(status);
    this.updateStopButtonVisibility();
  }

  #handleConnected() {
    this.#setConnectionState('connected');

    if (this.#isIdleSearch()) {
      this.isSearchFinished = true;
      this.#hideMessage();
      this.#updateResultsDisplay();
      this.updateStopButtonVisibility();
      return;
    }

    const data = {
      file_path: this.filePathValue,
      filter: this.filterInputTarget.value,
      mode: this.modeValue,
      regexp_mode: this.regexpModeValue
    };

    // Use range slider values if available and not at defaults
    const startSliderValue = parseInt(this.startSliderTarget.value);
    const endSliderValue = parseInt(this.endSliderTarget.value);

    if (!this.#isFullRange(startSliderValue, endSliderValue)) {
      data.start_position = startSliderValue;
      data.end_position = endSliderValue;
    } else if (this.modeValue === 'static' && this.endPositionValue > 0) {
      // Byte-offset explore window - reads a bounded range
      data.start_position = this.startPositionValue;
      data.end_position = this.endPositionValue;
    }

    this.subscription.perform('initialize_watcher', data);

    this.updateStopButtonVisibility();
    this.#syncSearchPlaceholder();
  }

  #handleDisconnected() {
    this.#setConnectionState('disconnected');
  }

  #handleRejected() {
    this.#setConnectionState('rejected');
  }

  #handleLogLines(lines) {
    const MAX_ROWS_LIVE_MODE = 150_000;
    const BATCH_REMOVE_SIZE = 50_000;

    try {
      // Append new lines to clusterize
      if (!lines || lines.length === 0) return;

      // Render JSON log lines into HTML strings
      const renderedLines = lines.map(line => this.#renderLogLineHtml(line));
      this.clusterize.append(renderedLines);

      // In live mode, prune old rows if we exceed the maximum
      if (this.isLiveMode() && this.clusterize.getRowsAmount() > MAX_ROWS_LIVE_MODE) {
        this.clusterize.prune(BATCH_REMOVE_SIZE);
      }

      // Highlight context line around byte offset if present
      const params = new URLSearchParams(window.location.search);
      if (params.has('byte_offset') && !this.contextLineHighlighted) {
        setTimeout(() => {
          this.#highlightContextLine();
          this.contextLineHighlighted = true;
        }, 100);
      }

      this.#updateResultsDisplay();
      this.scroll();

      // Update stop button visibility after processing lines
      this.updateStopButtonVisibility();

    } catch (error) {
      console.error('Error handling log lines:', error);
    }
  }

  #renderLogLineHtml(logLine) {
    // logLine is a JSON object: {content, byte_offset, show_expand_button}
    const { content, byte_offset, show_expand_button } = logLine;

    const hasOffset = byte_offset != null;

    if (hasOffset && show_expand_button) {
      return `<div style="display: flex; align-items: center;"><button class="onlylogs-expand-btn" data-byte-offset="${byte_offset}" data-action="click->log-streamer#handleExpandClick">+</button><pre data-byte-offset="${byte_offset}">${content}</pre></div>`;
    } else if (hasOffset) {
      return `<pre data-byte-offset="${byte_offset}">${content}</pre>`;
    } else {
      return `<pre>${content}</pre>`;
    }
  }

  #handleMessage(message) {
    const loadingIcon = message.endsWith('...') ? '<span class="onlylogs-spin-animation">⟳</span>' : '';
    this.messageTarget.innerHTML = message ? loadingIcon + message : '';
  }

  #handleFinish(message) {
    this.messageTarget.innerHTML = message;
    this.isSearchFinished = true;
    this.#updateResultsDisplay();
    this.updateStopButtonVisibility();
  }

  #handleError(message) {
    // Display error message with error styling
    this.messageTarget.innerHTML = `<span class="error-message">❌ ${message}</span>`;

    // Mark search as finished
    this.isSearchFinished = true;

    // Update stop button visibility (should hide it)
    this.updateStopButtonVisibility();

    // Stop the watcher
    this.stop();
  }

  #hideMessage() {
    this.messageTarget.innerHTML = '';
  }

  // Never silent: a live tail with a query that has not matched yet has to look
  // different from a search that came back empty, or the two are indistinguishable.
  #updateResultsDisplay() {
    const count = this.#formatNumber(this.clusterize.getRowsAmount());
    const hasFilter = this.filterInputTarget.value.trim() !== '';
    const results = this.resultsTarget;

    results.classList.remove('results-text--watching', 'results-text--live', 'results-text--found');

    this.#syncSearchPlaceholder();

    if (this.#isIdleSearch()) {
      results.textContent = 'No query';
      return;
    }

    if (!this.isLiveMode()) {
      results.textContent = `Results: ${count}`;
      if (this.isSearchFinished) results.classList.add('results-text--found');
      return;
    }

    if (hasFilter) {
      results.classList.add('results-text--watching');
      results.textContent = `⏳ watching · ${count} new since ${this.#liveFilterSinceLabel()}`;
    } else {
      results.classList.add('results-text--live');
      results.textContent = `${count} lines · live`;
    }
  }

  #liveFilterSinceLabel() {
    const since = this.#liveFilterStartedAt || new Date();
    return since.toTimeString().slice(0, 5);
  }

  #formatNumber(number) {
    return number.toString().replace(/\B(?=(\d{3})+(?!\d))/g, "'");
  }

  #updateWebsocketStatus(status) {
    if (!this.hasWebsocketStatusTarget) {
      return;
    }

    const statusElement = this.websocketStatusTarget;
    statusElement.className = `websocket-status websocket-status--${status}`;

    switch (status) {
      case 'connected':
        statusElement.innerHTML = '🟢';
        statusElement.title = 'WebSocket Connected';
        break;
      case 'disconnected':
        statusElement.innerHTML = '🔴';
        statusElement.title = 'WebSocket Disconnected';
        break;
      case 'rejected':
        statusElement.innerHTML = '🟡';
        statusElement.title = 'WebSocket Connection Rejected';
        break;
      default:
        statusElement.innerHTML = '⚪';
        statusElement.title = 'WebSocket Status Unknown';
    }
  }

  #initializeClusterize() {
    this.clusterize = new window.Clusterize({
      scrollId: 'scrollArea',
      contentId: 'contentArea',
      rows: [],
      tag: 'pre',
      rows_in_block: 50,
      blocks_in_cluster: 4,
      show_no_data_row: false,
      no_data_text: 'No log lines available',
      no_data_class: 'clusterize-no-data',
      keep_parity: true,
      callbacks: {
        clusterChanged: () => {
          // Re-apply highlighting when cluster changes (for virtual scrolling).
          // The byte_offset URL param is the highlight anchor for an explore window.
          // Only re-highlight if we've already done initial highlight.
          if (this.contextLineHighlighted) {
            const params = new URLSearchParams(window.location.search);
            if (params.has('byte_offset')) {
              const target = Number(params.get('byte_offset'));
              if (!Number.isNaN(target)) {
                this.#applyContextLineHighlight(target);
              }
            }
          }
        }
      }
    });
  }

  #reinitializeClusterize() {
    this.clusterize.destroy();
    this.clusterize = null;
    this.#initializeClusterize();
  }

  #updateUrlParam(param, value = null) {
    this.#updateUrlParams({ [param]: value });
  }

  #updateUrlParams(updates = {}) {
    const params = new URLSearchParams(window.location.search);

    // Update all params in one go
    Object.entries(updates).forEach(([param, value]) => {
      if (value != null) {
        params.set(param, value);
      } else {
        params.delete(param);
      }
    });

    const newUrl = `${window.location.pathname}?${params.toString()}`;

    // Update URL immediately so subsequent #updateUrlParams calls read the latest state.
    // Without this, each call reads the same stale window.location.search and params don't accumulate.
    window.history.replaceState(null, '', newUrl);

    // Debounce pushState to create a history entry (enables back button) without
    // spamming history on rapid updates like slider drag.
    if (this.historyUpdateTimeout) {
      clearTimeout(this.historyUpdateTimeout);
    }
    this.historyUpdateTimeout = setTimeout(() => {
      window.history.pushState(null, '', newUrl);
      this.historyUpdateTimeout = null;
    }, 1000);
  }

  // A range input snaps its value to `step` from `min`, so the end thumb can never
  // land exactly on a file size that is not a multiple of the step. Anything within
  // one step of the end is the whole file, not a range a few hundred bytes short.
  #isFullRange(start, end) {
    const step = Number(this.endSliderTarget.step) || 1;

    return start <= 0 && end >= this.fileSizeValue - step;
  }

  // The live values of the two handles.
  #currentRange() {
    return { start: Number(this.startSliderTarget.value), end: Number(this.endSliderTarget.value) };
  }
}
