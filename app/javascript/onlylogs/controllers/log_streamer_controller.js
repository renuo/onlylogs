import { Controller } from "@hotwired/stimulus";
import { createConsumer } from "@rails/actioncable";

export default class LogStreamerController extends Controller {
  static values = {
    filePath: { type: String },
    streamChannel: { type: String },
    cursorPosition: { type: Number, default: 0 },
    lastLineNumber: { type: Number, default: 0 },
    autoScroll: { type: Boolean, default: true },
    autoStart: { type: Boolean, default: true }
  };
  
  connect() {
    console.log(`LogStreamerController connected for file: ${this.filePathValue}`);
    // Initialize ActionCable consumer
    this.consumer = createConsumer();
    
    // Internal state
    this.receivedLines = new Map();
    this.missingLinePlaceholders = new Map();
    this.subscription = null;
    this.isRunning = false;

    if (this.autoStartValue) {
      this.start();
    }

    this.scroll();
  }
  
  disconnect() {
    this.stop();
  }
  
  /**
   * Start log streaming
   */
  start() {
    if (this.isRunning) {
      return;
    }
    
    this.isRunning = true;
    this.#initializeExistingLines();
    this.#createSubscription();
  }
  
  /**
   * Stop log streaming
   */
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
  
  /**
   * Clear log display
   */
  clear() {
    this.receivedLines.clear();
    this.missingLinePlaceholders.clear();
    this.element.innerHTML = '';
  }
  
  /**
   * Toggle auto-scroll
   */
  toggleAutoScroll() {
    this.autoScrollValue = !this.autoScrollValue;
  }

  scroll() {
    if (this.autoScrollValue) {
      this.element.scrollTop = this.element.scrollHeight;
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
        if (data.action === 'append_log') {
          this.#handleLogLine(data.line_number, data.content, data.html);
        }
      }
    });
  }
  
  /**
   * Handle successful connection
   */
  #handleConnected() {
    console.log(`Sending last line number: ${this.lastLineNumberValue}, cursor position: ${this.cursorPositionValue} for file: ${this.filePathValue}`);
    
    this.subscription.perform('initialize_watcher', {
      cursor_position: this.cursorPositionValue,
      last_line_number: this.lastLineNumberValue,
      file_path: this.filePathValue
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
      }
    });
    
    console.log(`Initialized with ${this.receivedLines.size} existing lines`);
  }
  
  /**
   * Handle incoming log line
   */
  #handleLogLine(lineNumber, content, html) {
    try {
      console.log("received line", lineNumber, content, html);
      // Store the received line
      this.receivedLines.set(lineNumber, { content, html });
      
      // Check if we need to insert missing line placeholders
      const maxLineNumber = Math.max(...this.receivedLines.keys());
      const minLineNumber = Math.min(...this.receivedLines.keys());
      
      // Add missing line placeholders for any gaps
      for (let i = minLineNumber; i <= maxLineNumber; i++) {
        if (!this.receivedLines.has(i) && !this.missingLinePlaceholders.has(i)) {
          this.#addMissingLinePlaceholder(i);
        }
      }
      
      // Update the display
      this.#updateLogDisplay();            
      
    } catch (error) {
      console.error('Error handling log line:', error);
    }
  }
  
  /**
   * Add missing line placeholder
   */
  #addMissingLinePlaceholder(lineNumber) {
    const placeholderHtml = `<pre data-line-number="${lineNumber}"><span style="color: #aaa; user-select: none; margin-right: 0.5em;">${lineNumber.toString().padStart(4)}</span> <span style="color: #ff6b6b; font-style: italic;">[NOT RECEIVED]</span></pre>`;
    this.missingLinePlaceholders.set(lineNumber, placeholderHtml);
  }
  
  /**
   * Update log display in the DOM
   */
  #updateLogDisplay() {
    // Clear the container
    this.element.innerHTML = '';
    
    // Get all line numbers (both received and missing)
    const allLineNumbers = new Set([
      ...this.receivedLines.keys(),
      ...this.missingLinePlaceholders.keys()
    ]);
    
    // Sort line numbers
    const sortedLineNumbers = Array.from(allLineNumbers).sort((a, b) => a - b);
    
    // Build the HTML in order
    sortedLineNumbers.forEach(lineNumber => {
      if (this.receivedLines.has(lineNumber)) {
        // Use the received line (this will override any placeholder)
        this.element.insertAdjacentHTML('beforeend', this.receivedLines.get(lineNumber).html);
        // Remove the placeholder if it exists
        this.missingLinePlaceholders.delete(lineNumber);
      } else if (this.missingLinePlaceholders.has(lineNumber)) {
        // Use the missing line placeholder
        this.element.insertAdjacentHTML('beforeend', this.missingLinePlaceholders.get(lineNumber));
      }
    });

    console.log("updated log display.scrolling...", this.autoScrollValue);

    this.scroll();
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
