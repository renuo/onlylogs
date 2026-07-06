import { Controller } from "@hotwired/stimulus";
import { createConsumer } from "@rails/actioncable";

export default class LogStreamerController extends Controller {
  static values = {
    filePath: { type: String },
    autoScroll: { type: Boolean, default: true },
    autoStart: { type: Boolean, default: true },
    filter: { type: String, default: '' },
    mode: { type: String, default: 'live' },
    regexpMode: { type: Boolean, default: false },
    fileSize: { type: Number, default: 0 },
    startPosition: { type: Number, default: 0 },
    endPosition: { type: Number, default: 0 }
  };

  static targets = ["logLines", "filterInput", "results", "liveMode", "message", "regexpMode", "websocketStatus", "stopButton", "clearButton", "autoscroll", "rangeSliderContainer", "startSlider", "endSlider", "startOutput", "endOutput"];

  connect() {
    this.consumer = createConsumer();

    this.subscription = null;
    this.isRunning = false;
    this.reconnectTimeout = null;
    this.isSearchFinished = true;
    this.lastRangeStep = null;
    this.historyUpdateTimeout = null;
    this.contextLineHighlighted = false;

    // Initialize clusterize
    this.clusterize = null;
    this.#initializeClusterize();

    this.#updateWebsocketStatus('disconnected');

    // Listen for range-slider updates
    if (this.hasRangeSliderContainerTarget) {
      this.rangeSliderContainerTarget.addEventListener('range:update', (e) => {
        this.#handleRangeUpdate(e);
      });
    }

    // Restore state from URL params if present
    this.#restoreStateFromUrl();

    // Listen for browser back/forward button clicks
    window.addEventListener('popstate', () => {
      this.#restoreStateFromUrl();
      this.reconnectWithNewMode();
    });

    this.start();
    this.updateLiveModeState();
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
    // Triggered by TextSelectionController#handleMouseDown via text-selection:start event
    // Enter "highlighting mode" - disable both autoscroll and live mode
    if (this.autoScrollValue) {
      this.autoScrollValue = false;
      this.autoscrollTarget.checked = false;
    }

    if (this.isLiveMode()) {
      this.liveModeTarget.checked = false;
      this.modeValue = 'static';
      this.updateLiveModeState();
      this.stop();
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

  toggleLiveMode() {
    if (this.isLiveMode()) {
      // User checked - enable live mode
      // Stop current operation and wait for backend to fully stop
      this.stop();

      // Clear highlighting
      this.#clearHighlighting();

      // Update state immediately
      this.modeValue = 'live';
      this.#setRange(0, this.fileSizeValue);
      this.#updateUrlParam('start_position', null);
      this.#updateUrlParam('end_position', null);
      this.#updateUrlParam('byte_offset', null);
      this.updateLiveModeState();

      if (!this.isRunning) {
        // Wait for backend to fully stop the current search, then reconnect
        setTimeout(() => {
          this.clear();
          this.#reinitializeClusterize();
          this.start();
        }, 1000);
      }


    } else {
      // User unchecked - disable live mode and pause
      this.modeValue = 'static';
      this.updateLiveModeState();
      this.stop();
    }
  }

  applyFilter() {
    const filterValue = this.filterInputTarget.value;

    // A filter switches to static mode; an empty filter goes back to live.
    if (filterValue && filterValue.trim() !== '') {
      this.liveModeTarget.checked = false;
      this.modeValue = 'static';
    } else {
      this.liveModeTarget.checked = true;
      this.modeValue = 'live';
    }

    // Applying a filter searches the whole file, so drop any explore window.
    this.startPositionValue = 0;
    this.endPositionValue = this.fileSizeValue;

    // Clear byte_offset and highlighting when applying a new filter
    this.#clearHighlighting();
    this.#updateUrlParam('byte_offset', null);

    // Update visual state
    this.updateLiveModeState();
    this.updateStopButtonVisibility();
    this.#updateUrlParam('filter', filterValue || null);

    // Use the global debounced reconnection (300ms delay)
    this.reconnectWithNewMode();
  }

  isLiveMode() {
    return this.liveModeTarget.checked;
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
      this.stop();
      this.clear();
      this.#reinitializeClusterize();
      this.start();
      this.reconnectTimeout = null;
    }, 600);
  }

  clearFilter() {
    // Clear filter and explore window to go back to pure live mode
    this.filterInputTarget.value = '';
    this.modeValue = 'live';
    this.startPositionValue = 0;
    this.endPositionValue = this.fileSizeValue;

    // Clear highlighting
    this.#clearHighlighting();

    // Re-enable live mode checkbox
    this.liveModeTarget.checked = true;

    // Update visual state
    this.updateLiveModeState();
    this.updateStopButtonVisibility();

    // Update URL with cleared filter
    this.#updateUrlParam('filter', null);
    this.#updateUrlParam('byte_offset', null);

    // Reconnect with cleared filter and live mode
    this.reconnectWithNewMode();
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

    // Clear filter and switch to static mode
    this.filterInputTarget.value = '';
    this.modeValue = 'static';
    this.liveModeTarget.checked = false;

    // Update URL with byte_offset and range
    this.#updateUrlParam('byte_offset', byteOffset);
    this.#updateUrlParam('filter', null);
    this.#updateUrlParam('start_position', start);
    this.#updateUrlParam('end_position', end);

    this.contextLineHighlighted = false;
    this.updateLiveModeState();
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
    // Find the row wrapper that's a direct child of clusterize-content
    let row = element;
    while (row.parentElement && !row.parentElement.classList.contains('clusterize-content')) {
      row = row.parentElement;
    }

    if (!row) return;

    // Scroll into view first to ensure element is rendered
    row.scrollIntoView({ behavior: 'smooth', block: 'center' });
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

  updateLiveModeState() {
    const liveModeLabel = this.liveModeTarget.closest('label');
    const hasFilter = this.filterInputTarget.value && this.filterInputTarget.value.trim() !== '';

    if (hasFilter) {
      liveModeLabel.classList.add('live-mode-sticky');
      this.liveModeTarget.disabled = true;
    } else {
      liveModeLabel.classList.remove('live-mode-sticky');
      this.liveModeTarget.disabled = false;
    }
  }

  updateStopButtonVisibility() {
    const shouldShow = this.modeValue === 'static' && this.subscription && this.isRunning && !this.isSearchFinished;
    this.stopButtonTarget.style.display = shouldShow ? 'inline-block' : 'none';
  }

  #setRange(start, end) {
    this.startSliderTarget.value = start;
    this.endSliderTarget.value = end;

    // Trigger range-slider controller to update visuals
    if (this.hasRangeSliderContainerTarget) {
      this.rangeSliderContainerTarget.dispatchEvent(new Event('input', { bubbles: true }));
    }

    // Also update visuals for log-streamer
    this.updateRangeVisuals();
  }

  #handleRangeUpdate() {
    const start = parseInt(this.startSliderTarget.value);
    const end = parseInt(this.endSliderTarget.value);
    const isDefaultRange = start === 0 && end === this.fileSizeValue;

    this.liveModeTarget.checked = isDefaultRange;
    this.modeValue = isDefaultRange ? 'live' : 'static';
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

    this.updateLiveModeState();
    this.reconnectWithNewMode();
  }

  resetRange() {
    this.#setRange(0, this.fileSizeValue);
    this.#handleRangeUpdate();
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

    // Calculate mode: static if filter or non-default range, otherwise live
    if (this.filterInputTarget.value.trim() !== '' || (startParam || endParam)) {
      this.modeValue = 'static';
      this.liveModeTarget.checked = false;
    } else {
      this.modeValue = 'live';
      this.liveModeTarget.checked = true;
    }
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
  #handleConnected() {
    const data = {
      file_path: this.filePathValue,
      filter: this.filterInputTarget.value,
      mode: this.modeValue,
      regexp_mode: this.regexpModeValue
    };

    // Use range slider values if available and not at defaults
    const startSliderValue = parseInt(this.startSliderTarget.value);
    const endSliderValue = parseInt(this.endSliderTarget.value);

    if (startSliderValue > 0 || endSliderValue < this.fileSizeValue) {
      data.start_position = startSliderValue;
      data.end_position = endSliderValue;
    } else if (this.modeValue === 'static' && this.endPositionValue > 0) {
      // Byte-offset explore window - reads a bounded range
      data.start_position = this.startPositionValue;
      data.end_position = this.endPositionValue;
    }

    this.subscription.perform('initialize_watcher', data);

    this.element.classList.add("log-streamer--connected");
    this.element.classList.remove("log-streamer--disconnected", "log-streamer--rejected");
    this.#updateWebsocketStatus('connected');
    this.updateStopButtonVisibility();
  }

  #handleDisconnected() {
    this.element.classList.add("log-streamer--disconnected");
    this.element.classList.remove("log-streamer--connected");
    this.#updateWebsocketStatus('disconnected');
    this.updateStopButtonVisibility();
  }

  #handleRejected() {
    this.element.classList.add("log-streamer--rejected");
    this.element.classList.remove("log-streamer--connected", "log-streamer--disconnected");
    this.#updateWebsocketStatus('rejected');
    this.updateStopButtonVisibility();
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

    if (byte_offset && show_expand_button) {
      return `<div style="display: flex; align-items: center;"><button class="onlylogs-expand-btn" data-byte-offset="${byte_offset}" data-action="click->log-streamer#handleExpandClick">+</button><pre data-byte-offset="${byte_offset}">${content}</pre></div>`;
    } else if (byte_offset) {
      return `<pre data-byte-offset="${byte_offset}">${content}</pre>`;
    } else {
      return `<pre>${content}</pre>`;
    }
  }

  #handleMessage(message) {
    this.#hideMessage();
      if (message === '') {
      this.messageTarget.innerHTML = "";
    } else {
      const loadingIcon = message.endsWith('...') ? '<span class="onlylogs-spin-animation">⟳</span>' : '';
      this.messageTarget.innerHTML = loadingIcon + message;
    }
  }

  #handleFinish(message) {
    this.messageTarget.innerHTML = message;
    this.isSearchFinished = true;
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

  #updateResultsDisplay() {
    const resultsCount = this.clusterize.getRowsAmount();
    this.resultsTarget.textContent = `Results: ${this.#formatNumber(resultsCount)}`;
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

  getStatus() {
    return {
      isRunning: this.isRunning,
      filePath: this.filePathValue,
      lineCount: this.clusterize.getRowsAmount(),
      connected: this.subscription && this.subscription.identifier
    };
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
        clusterWillChange: () => {
          // Optional: handle cluster change
        },
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
        },
        scrollingProgress: (progress) => {
          // Optional: handle scrolling progress
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

  // Range slider methods
  updateRangeVisuals(event) {
    let start = Number(this.startSliderTarget.value);
    let end = Number(this.endSliderTarget.value);
    const sliderMax = Number(this.startSliderTarget.max);
    const step = Number(this.startSliderTarget.step);

    // Snap to 100% if close to max (within 2% or one step)
    const threshold = Math.max(sliderMax * 0.02, step);
    if (end > sliderMax - threshold) {
      end = sliderMax;
      this.endSliderTarget.value = end;
    }
    if (start > sliderMax - threshold) {
      start = sliderMax;
      this.startSliderTarget.value = start;
    }

    // Enforce start <= end
    if (start > end) {
      [start, end] = [end, start];
      this.startSliderTarget.value = start;
      this.endSliderTarget.value = end;
    }

    this.#updateRangeDisplay(start, end);

    if (event?.type === 'change') {
      const step = this.#stepForRange(start, end);
      if (step !== this.lastRangeStep) {
        this.lastRangeStep = step;
        this.startSliderTarget.step = step;
        this.endSliderTarget.step = step;
      }

      this.rangeSliderContainerTarget.dispatchEvent(new CustomEvent("range:update", { detail: { start, end } }));
    }
  }

  #stepForRange(start, end) {
    const selectedBytes = Math.max(end - start, 1);
    const step = 10 ** Math.ceil(Math.log10(selectedBytes / 200));

    return Math.max(1, step);
  }

  #updateRangeDisplay(start, end) {
    const sliderMax = Number(this.startSliderTarget.max);

    this.rangeSliderContainerTarget.style.setProperty("--range-start-percent", `${(start / sliderMax) * 100}%`);
    this.rangeSliderContainerTarget.style.setProperty("--range-end-percent", `${(end / sliderMax) * 100}%`);

    this.startOutputTarget.textContent = `${this.#formatPercent(start)}%`;
    this.endOutputTarget.textContent = `${this.#formatPercent(end)}%`;
  }

  #formatPercent(value) {
    // Show 100% if within 1% of file size
    if (value >= this.fileSizeValue * 0.99) return '100.0';
    if (value <= 0) return '0.0';
    const percent = (value / this.fileSizeValue) * 100;
    return percent.toFixed(1);
  }
}
