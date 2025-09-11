import { Controller } from "@hotwired/stimulus";
import { createConsumer } from "@rails/actioncable";

export default class LogStreamerController extends Controller {
  static values = {
    filePath: { type: String },
    streamChannel: { type: String },
    cursorPosition: { type: Number, default: 0 },
    lastLineNumber: { type: Number, default: 0 },
    autoScroll: { type: Boolean, default: true },
    autoStart: { type: Boolean, default: true },
    filter: { type: String, default: '' },
    mode: { type: String, default: 'live' }
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
    this.subscription = this.consumer.subscriptions.create(this.streamChannelValue, {
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
        if (data.action === 'append_log') {
          this.#handleLogLine(data.line_number, data.content, data.html);
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
    console.log(`Sending last line number: ${this.lastLineNumberValue}, cursor position: ${this.cursorPositionValue} for file: ${this.filePathValue} in mode: ${this.modeValue}`);
    
    this.subscription.perform('initialize_watcher', {
      cursor_position: this.cursorPositionValue,
      last_line_number: this.lastLineNumberValue,
      file_path: this.filePathValue,
      filter: this.filterInputTarget.value,
      mode: this.modeValue
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
          content: preElement.textContent.trim(),
          html: preElement.outerHTML
        });
        // Update the last rendered line number
        this.lastRenderedLineNumber = Math.max(this.lastRenderedLineNumber, lineNumber);
      }
    });
    
    console.log(`Initialized with ${this.receivedLines.size} existing lines, last rendered: ${this.lastRenderedLineNumber}`);
  }
  
  /**
   * Handle incoming log line - now uses batching for better performance
   */
  #handleLogLine(lineNumber, content, html) {
    try {
      console.log("received line", lineNumber);
      // Store the received line
      this.receivedLines.set(lineNumber, { content, html });
      
      // Add to pending lines for batch processing
      this.pendingLines.set(lineNumber, { content, html });

      // TODO: re-enable?
      // Check if we need to insert missing line placeholders
      // const { min: minLineNumber, max: maxLineNumber } = this.#getLineNumberRange();
      
      // Add missing line placeholders for any gaps
      // for (let i = minLineNumber; i <= maxLineNumber; i++) {
      //   if (!this.receivedLines.has(i) && !this.missingLinePlaceholders.has(i)) {
      //     this.#addMissingLinePlaceholder(i);
      //   }
      // }
      
      // Schedule batch update if not already scheduled
      this.#scheduleBatchUpdate();
      
    } catch (error) {
      console.error('Error handling log line:', error);
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
  
  /**
   * Update log display progressively by only appending new lines
   * This is much more efficient than re-rendering everything
   */
  #updateLogDisplay() {
    let container = this.logLinesTarget;
    
    // Get sorted line numbers
    const sortedLineNumbers = this.#getSortedLineNumbers();
    
    // Find the range of new lines to append
    const newLinesToRender = sortedLineNumbers.filter(lineNumber => lineNumber > this.lastRenderedLineNumber);
    
    if (newLinesToRender.length === 0) {
      // No new lines to render, just update the display info
      this.#updateLineRangeDisplay();
      this.scroll();
      return;
    }
    
    // Append only the new lines
    newLinesToRender.forEach(lineNumber => {
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
    });

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
    
    const { min: minLineNumber, max: maxLineNumber } = this.#getLineNumberRange();
    
    if (minLineNumber === null || maxLineNumber === null) {
      this.lineRangeTarget.textContent = "No lines";
      return;
    }
    
    if (minLineNumber === maxLineNumber) {
      this.lineRangeTarget.textContent = `Line ${minLineNumber}`;
    } else {
      this.lineRangeTarget.textContent = `Lines ${minLineNumber}-${maxLineNumber}`;
    }
  }
  
  /**
   * Get all line numbers (both received and missing)
   */
  #getAllLineNumbers() {
    const allNumbers = new Set();
    
    // Add received line numbers
    for (const lineNumber of this.receivedLines.keys()) {
      allNumbers.add(lineNumber);
    }
    
    // Add missing line numbers
    for (const lineNumber of this.missingLinePlaceholders.keys()) {
      allNumbers.add(lineNumber);
    }
    
    return allNumbers;
  }
  
  /**
   * Get sorted array of all line numbers
   */
  #getSortedLineNumbers() {
    const allNumbers = this.#getAllLineNumbers();
    const sortedArray = [];
    
    // Convert Set to Array efficiently
    for (const lineNumber of allNumbers) {
      sortedArray.push(lineNumber);
    }
    
    return sortedArray.sort((a, b) => a - b);
  }
  
  /**
   * Get min and max line numbers - optimized for large datasets
   */
  #getLineNumberRange() {
    let min = null;
    let max = null;
    
    // Find min and max in a single pass without using spread operator
    for (const lineNumber of this.receivedLines.keys()) {
      if (min === null || lineNumber < min) min = lineNumber;
      if (max === null || lineNumber > max) max = lineNumber;
    }
    
    for (const lineNumber of this.missingLinePlaceholders.keys()) {
      if (min === null || lineNumber < min) min = lineNumber;
      if (max === null || lineNumber > max) max = lineNumber;
    }
    
    return { min, max };
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
