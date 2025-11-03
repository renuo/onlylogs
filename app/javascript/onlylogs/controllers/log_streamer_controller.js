import { Controller } from "@hotwired/stimulus";
import { createConsumer } from "@rails/actioncable";

export default class LogStreamerController extends Controller {
  static values = {
    filePath: { type: String },
    cursorPosition: { type: Number, default: 0 },
    lastLineNumber: { type: Number, default: 0 },
    autoScroll: { type: Boolean, default: true },
    autoStart: { type: Boolean, default: true },
    filter: { type: String, default: '' },
    mode: { type: String, default: 'live' },
    regexpMode: { type: Boolean, default: false }
  };

  static targets = ["logLines", "filterInput", "lineRange", "liveMode", "message", "regexpMode", "websocketStatus", "stopButton", "clearButton"];

  connect() {
    this.consumer = createConsumer();

    this.subscription = null;
    this.isRunning = false;
    this.reconnectTimeout = null;
    this.minLineNumber = null;
    this.maxLineNumber = 0;
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
    this.minLineNumber = null;
    this.maxLineNumber = 0;

    this.clusterize.clear();

    this.#updateLineRangeDisplay();
  }

  toggleAutoScroll() {
    this.autoScrollValue = !this.autoScrollValue;
    this.scroll();
  }

  toggleRegexpMode() {
    this.regexpModeValue = this.regexpModeTarget.checked;
    // If we have a filter applied, reconnect to apply the new regexp mode
    if (this.filterInputTarget.value && this.filterInputTarget.value.trim() !== '') {
      this.reconnectWithNewMode();
    }
  }

  toggleLiveMode() {
    // this condition looks revered, but the value here has been changed already. so the live mode has been enabled.
    if (this.isLiveMode()) {
      this.clearFilter();
      this.modeValue = 'live';
      this.reconnectWithNewMode();
      return;
    }
    else {
      this.liveModeTarget.checked = true;
      return false;
    }
  }

  applyFilter() {
    // If filter is applied, disable live mode
    if (this.filterInputTarget.value && this.filterInputTarget.value.trim() !== '') {
      this.liveModeTarget.checked = false;
      this.modeValue = 'search';
    } else {
      // If no filter, enable live mode
      this.liveModeTarget.checked = true;
      this.modeValue = 'live';
    }

    // Update visual state
    this.updateLiveModeState();
    this.updateStopButtonVisibility();

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
    // Clear the filter input
    this.filterInputTarget.value = '';

    // Re-enable live mode
    this.liveModeTarget.checked = true;
    this.modeValue = 'live';

    // Update visual state
    this.updateLiveModeState();
    this.updateStopButtonVisibility();

    // Reconnect with cleared filter and live mode
    this.reconnectWithNewMode();
  }

  stopSearch() {
    if (this.subscription && this.isRunning) {
      this.subscription.perform('stop_watcher');
    }
  }

  clearLogs() {
    this.clear();
    this.#hideMessage();
  }

  updateLiveModeState() {
    const liveModeLabel = this.liveModeTarget.closest('label');

    if (this.isLiveMode()) {
      liveModeLabel.classList.remove('live-mode-sticky');
    } else {
      liveModeLabel.classList.add('live-mode-sticky');
    }
  }

  updateStopButtonVisibility() {
    const shouldShow = !this.isLiveMode() && this.subscription && this.isRunning && !this.isSearchFinished;
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
        }
      }
    });
  }

  /**
   * Handle successful connection
   */
  #handleConnected() {
    this.subscription.perform('initialize_watcher', {
      cursor_position: this.cursorPositionValue,
      last_line_number: this.lastLineNumberValue,
      file_path: this.filePathValue,
      filter: this.filterInputTarget.value,
      mode: this.modeValue,
      fast: this.fastValue,
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
    try {
      const newLines = [];

      lines.forEach(line => {
        const { line_number, html } = line;

        if (this.minLineNumber === null || line_number < this.minLineNumber) {
          this.minLineNumber = line_number;
        }
        this.maxLineNumber = Math.max(this.maxLineNumber, line_number);

        // Add to new lines array for clusterize
        newLines.push(html);
      });

      // Append new lines to clusterize
      if (newLines.length > 0) {
        this.clusterize.append(newLines);
        this.#updateLineRangeDisplay();
        this.scroll();
      }

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
    // Display the finish message without loading icon
    this.messageTarget.innerHTML = message;

    // Mark search as finished
    this.isSearchFinished = true;

    // Update stop button visibility (should hide it)
    this.updateStopButtonVisibility();
  }

  #hideMessage() {
    this.messageTarget.innerHTML = '';
  }

  #updateLineRangeDisplay() {
    const resultsCount = this.clusterize.getRowsAmount();
    let lineRangeText;

    if (this.minLineNumber === null || this.maxLineNumber === 0) {
      lineRangeText = `No lines`;
    } else if (this.minLineNumber === this.maxLineNumber) {
      lineRangeText = `Line ${this.#formatNumber(this.minLineNumber)}`;
    } else {
      lineRangeText = `Lines ${this.#formatNumber(this.minLineNumber)} - ${this.#formatNumber(this.maxLineNumber)}`;
    }

    this.lineRangeTarget.textContent = `${lineRangeText} | Results: ${this.#formatNumber(resultsCount)}`;
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
      cursorPosition: this.cursorPositionValue,
      lineCount: this.clusterize.getRowsAmount(),
      maxLineNumber: this.maxLineNumber,
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
}
