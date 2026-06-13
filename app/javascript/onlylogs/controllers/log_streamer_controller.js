import { Controller } from "@hotwired/stimulus";
import { createConsumer } from "@rails/actioncable";

export default class LogStreamerController extends Controller {
  static values = {
    filePath: { type: String },
    startPosition: { type: Number, default: 0 },
    endPosition: { type: Number, default: 0 },
    autoScroll: { type: Boolean, default: true },
    autoStart: { type: Boolean, default: true },
    filter: { type: String, default: '' },
    mode: { type: String, default: 'live' },
    regexpMode: { type: Boolean, default: false }
  };

  static targets = ["logLines", "filterInput", "byteOffsetInput", "results", "liveMode", "message", "regexpMode", "websocketStatus", "stopButton", "clearButton", "autoscroll"];

  connect() {
    this.consumer = createConsumer();

    this.subscription = null;
    this.isRunning = false;
    this.reconnectTimeout = null;
    this.isSearchFinished = true;
    this.contextLineHighlighted = false;

    // Initialize clusterize
    this.clusterize = null;
    this.#initializeClusterize();

    this.#updateWebsocketStatus('disconnected');

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
      this.modeValue = 'live';
      this.clearFilter();
      this.updateLiveModeState();
      if (!this.isRunning) {
        this.start();
      }
    } else {
      // Prevent unchecking - live mode can only be disabled by applying a filter
      this.liveModeTarget.checked = true;
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
    this.endPositionValue = 0;

    // Update visual state
    this.updateLiveModeState();
    this.updateStopButtonVisibility();
    this.#updateUrlParam('filter', filterValue || null);
    this.#updateUrlParam('byte_offset', null);
    this.byteOffsetInputTarget.value = '';

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
    this.byteOffsetInputTarget.value = '';
    this.modeValue = 'live';
    this.startPositionValue = 0;
    this.endPositionValue = 0;
    this.contextLineHighlighted = false;

    // Remove any highlighting
    this.logLinesTarget.querySelectorAll('.highlighted-context-line').forEach(el => {
      el.classList.remove('highlighted-context-line');
    });

    // Re-enable live mode checkbox
    this.liveModeTarget.checked = true;

    // Update visual state
    this.updateLiveModeState();
    this.updateStopButtonVisibility();

    // Update URL with cleared params
    this.#updateUrlParam('filter', null);
    this.#updateUrlParam('byte_offset', null);

    // Reconnect with cleared filter and live mode
    this.reconnectWithNewMode();
  }

  stopSearch() {
    console.log("stop search");
    this.subscription.perform('stop_watcher');
  }

  clearLogs() {
    this.clear();
    this.#hideMessage();
  }

  jumpToByteOffset(e) {
    if (e instanceof KeyboardEvent && e.key !== 'Enter') return;

    const byteOffset = this.byteOffsetInputTarget.value;
    if (!byteOffset || isNaN(byteOffset)) return;

    const params = new URLSearchParams(window.location.search);
    params.set('byte_offset', byteOffset);
    params.delete('filter');
    window.location.href = `${window.location.pathname}?${params.toString()}`;
  }

  handleExpandClick(e) {
    const btn = e.target.closest('.onlylogs-expand-btn');
    if (!btn) return;

    const byteOffset = btn.getAttribute('data-byte-offset');
    if (!byteOffset) return;

    const params = new URLSearchParams(window.location.search);
    params.set('byte_offset', byteOffset);
    params.delete('filter');
    params.set('autoscroll', 'false');
    params.delete('regexp_mode');

    window.location.href = `${window.location.pathname}?${params.toString()}`;
  }

  #highlightContextLine() {
    const target = Number(new URLSearchParams(window.location.search).get('byte_offset'));
    if (Number.isNaN(target)) return;

    this.#applyContextLineHighlight(target);

    // Only scroll on initial highlight
    if (!this.contextLineHighlighted) {
      const closestPre = [...this.logLinesTarget.querySelectorAll('pre[data-byte-offset]')]
        .find(pre => Number(pre.dataset.byteOffset) === target ||
          Math.abs(Number(pre.dataset.byteOffset) - target) < 1000);
      if (closestPre) {
        this.#scrollVerticallyToCenter(closestPre);
      }
    }
  }

  #scrollVerticallyToCenter(element) {
    const container = this.logLinesTarget;
    const containerRect = container.getBoundingClientRect();
    const elementRect = element.getBoundingClientRect();
    const delta = (elementRect.top - containerRect.top) - (container.clientHeight / 2) + (elementRect.height / 2);
    container.scrollBy({ top: delta, behavior: 'smooth' });
  }

  #applyContextLineHighlight(target) {
    const closestPre = [...this.logLinesTarget.querySelectorAll('pre[data-byte-offset]')]
      .reduce((closest, pre) => {
        const distance = Math.abs(Number(pre.dataset.byteOffset) - target);
        return !closest || distance < closest.distance ? { pre, distance } : closest;
      }, null)?.pre;

    if (!closestPre) return;

    const row = this.#rowElement(closestPre);
    [row.previousElementSibling, row, row.nextElementSibling]
      .filter(Boolean)
      .forEach(line => line.classList.add('highlighted-context-line'));
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
      this.liveModeTarget.disabled = true;
    } else {
      this.liveModeTarget.disabled = false;
    }
  }

  updateStopButtonVisibility() {
    const shouldShow = this.modeValue === 'static' && this.subscription && this.isRunning && !this.isSearchFinished;
    this.stopButtonTarget.style.display = shouldShow ? 'inline-block' : 'none';
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

    if (this.modeValue === 'static') {
      // A byte-offset explore window reads a bounded range. Without a window
      // (start/end), a static read is a whole-file filter search.
      if (this.endPositionValue > 0) {
        data.start_position = this.startPositionValue;
        data.end_position = this.endPositionValue;
      }
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
    try {
      // Append new lines to clusterize
      if (lines.length > 0) {
        // Render JSON log lines into HTML strings
        const renderedLines = lines.map(line => this.#renderLogLineHtml(line));
        this.clusterize.append(renderedLines);
        this.#updateResultsDisplay();
        this.scroll();

        // Find and highlight lines around the target byte offset
        const params = new URLSearchParams(window.location.search);
        if (params.has('byte_offset') && !this.contextLineHighlighted) {
          setTimeout(() => {
            this.#highlightContextLine();
            this.contextLineHighlighted = true;
          }, 100);
        }
      }

      // Update stop button visibility after processing lines
      this.updateStopButtonVisibility();

    } catch (error) {
      console.error('Error handling log lines:', error);
    }
  }

  #renderLogLineHtml(logLine) {
    // logLine is now a JSON object: {content, byte_offset, show_expand_button}
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
          const params = new URLSearchParams(window.location.search);
          if (params.has('byte_offset')) {
            const target = Number(params.get('byte_offset'));
            if (!Number.isNaN(target)) {
              this.#applyContextLineHighlight(target);
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
    const params = new URLSearchParams(window.location.search);

    if (value != null) {
      params.set(param, value);
    } else {
      params.delete(param);
    }

    const newUrl = `${window.location.pathname}?${params.toString()}`;
    window.history.replaceState(null, '', newUrl);
  }
}
