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
    fast: { type: Boolean, default: false }
  };

  static targets = ["logLines", "filterInput", "lineRange", "liveMode", "message"];
  
  connect() {
    console.log(`LogStreamerController connected for file: ${this.filePathValue} in ${this.modeValue} mode`);
    // Initialize ActionCable consumer
    this.consumer = createConsumer();
    console.log(this.logLinesTarget);

    // Internal state
    this.receivedLines = new Map();
    this.missingLinePlaceholders = new Map();
    this.subscription = null;
    this.isRunning = false;
    this.filterTimeout = null;
    this.lastRenderedLineNumber = 0; // Track the last line number that was rendered
    
    // Batching state for performance optimization
    this.pendingLines = new Map(); // Lines waiting to be rendered
    this.batchUpdateTimer = null; // Timer for batch updates
    this.batchInterval = 50;

    // Line range tracking
    this.minLineNumber = null;
    this.maxLineNumber = null;

    this.start();
    this.updateLiveModeState();
    this.scroll();
  }
  
  disconnect() {
    this.stop();
    
    // Clear any pending filter timeout
    if (this.filterTimeout) {
      clearTimeout(this.filterTimeout);
      this.filterTimeout = null;
    }
    
    // Clear batch update timer
    if (this.batchUpdateTimer) {
      clearTimeout(this.batchUpdateTimer);
      this.batchUpdateTimer = null;
    }
  }
  
  start() {
    if (this.isRunning) {
      return;
    }
    
    this.isRunning = true;
    this.#initializeExistingLines();
    this.#createSubscription();
  }
  
  stop() {
    if (!this.isRunning) {
      return;
    }
    
    this.isRunning = false;
    
    if (this.subscription) {
      this.subscription.unsubscribe();
      this.subscription = null;
    }
  }

  reset() {
    console.log(`Resetting log streamer with filter: ${this.filterInputTarget.value}`);
    this.stop();
    this.clear();
    this.start();
  }

  clear() {
    this.receivedLines.clear();
    this.missingLinePlaceholders.clear();
    this.pendingLines.clear(); // Clear pending lines
    this.logLinesTarget.innerHTML = '';
    this.lastRenderedLineNumber = 0; // Reset the last rendered line number
    
    // Reset line range tracking
    this.minLineNumber = null;
    this.maxLineNumber = null;
    
    // Clear any pending batch update timer
    if (this.batchUpdateTimer) {
      clearTimeout(this.batchUpdateTimer);
      this.batchUpdateTimer = null;
    }
    
    this.#updateLineRangeDisplay();
  }

  toggleAutoScroll() {
    this.autoScrollValue = !this.autoScrollValue;
    this.scroll();
  }

  toggleLiveMode() {
    // this condition looks revered, but the value here has been changed already. so the live mode has been enabled.
    if (this.isLiveMode()) {
      console.log("Clearing filter and restarting live mode");
      this.clearFilter();
      this.modeValue = 'live';      
      this.reconnectWithNewMode();
      return;
    }
    else {
      console.log("Cannot disable live mode");
      this.liveModeTarget.checked = true;
      return false;
    }
  }

  applyFilter() {
    // Clear any existing timeout
    if (this.filterTimeout) {
      clearTimeout(this.filterTimeout);
    }
    
    // Set a new timeout for 500ms (0.5 seconds)
    this.filterTimeout = setTimeout(() => {
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
      
      // Clear any pending batch updates when filter changes
      if (this.batchUpdateTimer) {
        clearTimeout(this.batchUpdateTimer);
        this.batchUpdateTimer = null;
      }
      
      // Reconnect with new mode and filter
      this.reconnectWithNewMode();
    }, 500);
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
    // Stop current connection
    this.stop();
    
    // Clear current logs
    this.clear();
    
    // Start new connection with updated mode
    this.start();
  }

  clearFilter() {
    // Clear the filter input
    this.filterInputTarget.value = '';
    
    // Re-enable live mode
    this.liveModeTarget.checked = true;
    this.modeValue = 'live';
    
    // Update visual state
    this.updateLiveModeState();
    
    // Reconnect with cleared filter and live mode
    this.reconnectWithNewMode();
  }

  updateLiveModeState() {
    const liveModeLabel = this.liveModeTarget.closest('label');
    
    if (this.isLiveMode()) {
      liveModeLabel.classList.remove('live-mode-sticky');
    } else {
      liveModeLabel.classList.add('live-mode-sticky');
    }
  }
  
  /**
   * Create ActionCable subscription
   */
  #createSubscription() {
    this.subscription = this.consumer.subscriptions.create("Onlylogs::LogsChannel", {
      connected: () => {
        console.log('Connected to logs channel');
        this.#handleConnected();
      },
      
      disconnected: () => {
        console.log('Disconnected from logs channel');
        this.#handleDisconnected();
      },
      
      rejected: () => {
        console.log('Failed to connect to logs channel');
        this.#handleRejected();
      },
      
      received: (data) => {
        this.#hideMessage();
        if (data.action === 'append_logs') {
          // Handle lines (can be single or multiple)
          this.#handleLogLines(data.lines);
        } else if (data.action === 'message') {
          this.#handleMessage(data.content);
        }
      }
    });
  }
  
  /**
   * Handle successful connection
   */
  #handleConnected() {
    console.log(`Sending last line number: ${this.lastLineNumberValue}, cursor position: ${this.cursorPositionValue} for file: ${this.filePathValue} in mode: ${this.modeValue}. Fast: ${this.fastValue}`);
    
    this.subscription.perform('initialize_watcher', {
      cursor_position: this.cursorPositionValue,
      last_line_number: this.lastLineNumberValue,
      file_path: this.filePathValue,
      filter: this.filterInputTarget.value,
      mode: this.modeValue,
      fast: this.fastValue
    });
    
    this.element.classList.add("log-streamer--connected");
    this.element.classList.remove("log-streamer--disconnected", "log-streamer--rejected");
  }
  
  /**
   * Handle disconnection
   */
  #handleDisconnected() {
    this.element.classList.add("log-streamer--disconnected");
    this.element.classList.remove("log-streamer--connected");
  }
  
  /**
   * Handle connection rejection
   */
  #handleRejected() {
    this.element.classList.add("log-streamer--rejected");
    this.element.classList.remove("log-streamer--connected", "log-streamer--disconnected");
  }
  
  /**
   * Initialize with existing lines from the DOM
   */
  #initializeExistingLines() {
    const existingPreElements = this.element.querySelectorAll('pre[data-line-number]');
    
    existingPreElements.forEach(preElement => {
      const lineNumber = parseInt(preElement.getAttribute('data-line-number'));
      if (!isNaN(lineNumber)) {
        this.receivedLines.set(lineNumber, {
          html: preElement.outerHTML
        });
        // Update the last rendered line number
        this.lastRenderedLineNumber = Math.max(this.lastRenderedLineNumber, lineNumber);
        
        // Update line range tracking
        if (this.minLineNumber === null || lineNumber < this.minLineNumber) {
          this.minLineNumber = lineNumber;
        }
        if (this.maxLineNumber === null || lineNumber > this.maxLineNumber) {
          this.maxLineNumber = lineNumber;
        }
      }
    });
    
    console.log(`Initialized with ${this.receivedLines.size} existing lines, last rendered: ${this.lastRenderedLineNumber}`);
  }
  
  #handleLogLines(lines) {
    try {
      console.log(`received ${lines.length} line(s)`);
      
      // Process all lines in the batch
      lines.forEach(line => {
        const { line_number, html } = line;
        
        // Store the received line
        this.receivedLines.set(line_number, { html });
        
        // Update line range tracking
        if (this.minLineNumber === null || line_number < this.minLineNumber) {
          this.minLineNumber = line_number;
        }
        if (this.maxLineNumber === null || line_number > this.maxLineNumber) {
          this.maxLineNumber = line_number;
        }
        
        // Add to pending lines for batch processing
        this.pendingLines.set(line_number, { html });
      });
      
      // Schedule batch update if not already scheduled
      this.#scheduleBatchUpdate();
      
    } catch (error) {
      console.error('Error handling log lines:', error);
    }
  }
  
  #handleMessage(message) {
    const loadingIcon = '<span class="onlylogs-spin-animation">⟳</span>';
    this.messageTarget.innerHTML = loadingIcon + message;
  }

  #hideMessage() {
    this.messageTarget.innerHTML = '';
  }

  /**
   * Add missing line placeholder
   */
  #addMissingLinePlaceholder(lineNumber) {
    const placeholderHtml = `<pre data-line-number="${lineNumber}"><span style="color: #aaa; user-select: none; margin-right: 0.5em;">${lineNumber.toString().padStart(4)}</span> <span style="color: #ff6b6b; font-style: italic;">[NOT RECEIVED]</span></pre>`;
    this.missingLinePlaceholders.set(lineNumber, placeholderHtml);
  }
  
  /**
   * Schedule a batch update if not already scheduled
   */
  #scheduleBatchUpdate() {
    if (this.batchUpdateTimer) {
      return; // Already scheduled
    }
    
    this.batchUpdateTimer = setTimeout(() => {
      this.#processBatchUpdate();
    }, this.batchInterval);
  }
  
  /**
   * Process all pending lines in a batch update
   */
  #processBatchUpdate() {
    if (this.pendingLines.size === 0) {
      this.batchUpdateTimer = null;
      return;
    }
    
    // Clear the timer
    this.batchUpdateTimer = null;
    
    // Process all pending lines
    this.#updateLogDisplay();
    
    // Clear pending lines after processing
    this.pendingLines.clear();
  }
  
  #updateLogDisplay() {
    let container = this.logLinesTarget;
    
    // If no lines have been received yet, nothing to render
    if (this.maxLineNumber === null) {
      this.#updateLineRangeDisplay();
      this.scroll();
      return;
    }
    
    // Find the range of new lines to append (from lastRenderedLineNumber + 1 to maxLineNumber)
    const startLineNumber = this.lastRenderedLineNumber + 1;
    const endLineNumber = this.maxLineNumber;
    
    if (startLineNumber > endLineNumber) {
      // No new lines to render, just update the display info
      this.#updateLineRangeDisplay();
      this.scroll();
      return;
    }
    
    // Append only the new lines in sequence
    for (let lineNumber = startLineNumber; lineNumber <= endLineNumber; lineNumber++) {
      if (this.receivedLines.has(lineNumber)) {
        // Use the received line (this will override any placeholder)
        container.insertAdjacentHTML('beforeend', this.receivedLines.get(lineNumber).html);
        // Remove the placeholder if it exists
        this.missingLinePlaceholders.delete(lineNumber);
      } else if (
        this.missingLinePlaceholders.has(lineNumber) &&
        this.isLiveMode() // Only show placeholders in live mode, not when filtering
      ) {
        // Use the missing line placeholder only in live mode
        container.insertAdjacentHTML('beforeend', this.missingLinePlaceholders.get(lineNumber));
      }
      
      // Update the last rendered line number
      this.lastRenderedLineNumber = Math.max(this.lastRenderedLineNumber, lineNumber);
    }

    this.#updateLineRangeDisplay();
    this.scroll();
  }
  
  /**
   * Update the line range display in the toolbar
   */
  #updateLineRangeDisplay() {
    if (!this.hasLineRangeTarget) {
      return;
    }
    
    if (this.minLineNumber === null || this.maxLineNumber === null) {
      this.lineRangeTarget.textContent = "No lines";
      return;
    }
    
    if (this.minLineNumber === this.maxLineNumber) {
      this.lineRangeTarget.textContent = `Line ${this.#formatNumber(this.minLineNumber)}`;
    } else {
      this.lineRangeTarget.textContent = `Lines ${this.#formatNumber(this.minLineNumber)} - ${this.#formatNumber(this.maxLineNumber)}`;
    }
  }

  /**
   * Format number with Ruby-style thousands separator (single quote)
   */
  #formatNumber(number) {
    return number.toString().replace(/\B(?=(\d{3})+(?!\d))/g, "'");
  }
  
  /**
   * Get current streaming status
   */
  getStatus() {
    return {
      isRunning: this.isRunning,
      filePath: this.filePathValue,
      cursorPosition: this.cursorPositionValue,
      lineCount: this.receivedLines.size,
      missingLines: this.missingLinePlaceholders.size,
      connected: this.subscription && this.subscription.identifier
    };
  }
}
