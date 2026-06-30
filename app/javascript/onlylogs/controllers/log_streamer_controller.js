import { Controller } from "@hotwired/stimulus";
import { createConsumer } from "@rails/actioncable";

export default class LogStreamerController extends Controller {
  static values = {
    filePath: { type: String },
    autoScroll: { type: Boolean, default: true },
    autoStart: { type: Boolean, default: true },
    filter: { type: String, default: '' },
    mode: { type: String, default: 'live' },
    regexpMode: { type: Boolean, default: false }
  };

  static targets = ["logLines", "filterInput", "results", "liveMode", "message", "regexpMode", "websocketStatus", "stopButton", "clearButton", "autoscroll"];

  connect() {
    this.consumer = createConsumer();

    this.subscription = null;
    this.isRunning = false;
    this.reconnectTimeout = null;
    this.isSearchFinished = true;

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
    // this condition looks revered, but the value here has been changed already. so the live mode has been enabled.
    if (this.isLiveMode()) {
      this.modeValue = 'live';
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
    // Clear filter to go back to pure live mode
    this.filterInputTarget.value = '';
    this.modeValue = 'live';

    // Re-enable live mode checkbox
    this.liveModeTarget.checked = true;

    // Update visual state
    this.updateLiveModeState();
    this.updateStopButtonVisibility();

    // Update URL with cleared filter
    this.#updateUrlParam('filter', null);

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
    this.subscription.perform('initialize_watcher', {
      file_path: this.filePathValue,
      filter: this.filterInputTarget.value,
      mode: this.modeValue,
      regexp_mode: this.regexpModeValue
    });

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

      this.clusterize.append(lines);

      // In live mode, prune old rows if we exceed the maximum
      if (this.isLiveMode() && this.clusterize.getRowsAmount() > MAX_ROWS_LIVE_MODE) {
        this.clusterize.prune(BATCH_REMOVE_SIZE);
      }

      this.#updateResultsDisplay();
      this.scroll();

      // Update stop button visibility after processing lines
      this.updateStopButtonVisibility();

    } catch (error) {
      console.error('Error handling log lines:', error);
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
          // Optional: handle after cluster change
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
