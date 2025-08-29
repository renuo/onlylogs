# Onlylogs Integration Guide

The Onlylogs engine automatically adapts to your Rails application's asset pipeline setup. Here's how it works with different configurations:

## Automatic Integration

The engine will automatically detect and integrate with your asset pipeline:

- **Importmap (Rails 7+ default)**: Uses ES modules and automatic registration
- **Sprockets**: Uses global namespace and manual registration  
- **Propshaft**: Uses dynamic imports and modern JavaScript

## Manual Integration (if needed)

If automatic integration doesn't work, you can manually register the Stimulus controller:

### For Importmap apps:

In your `app/javascript/application.js`:

```javascript
import LogStreamerController from "onlylogs/log_streamer_controller"

application.register("onlylogs--log-streamer", LogStreamerController)
```

### For Sprockets apps:

In your `app/assets/javascripts/application.js`:

```javascript
//= require onlylogs/log_streamer_controller

document.addEventListener("DOMContentLoaded", function() {
  if (window.Stimulus && window.Onlylogs && window.Onlylogs.LogStreamerController) {
    window.Stimulus.register("onlylogs--log-streamer", window.Onlylogs.LogStreamerController)
  }
})
```

### For Propshaft apps:

In your `app/assets/javascripts/application.js`:

```javascript
import LogStreamerController from "./onlylogs/log_streamer_controller.js"

application.register("onlylogs--log-streamer", LogStreamerController)
```

## Dependencies

The engine requires:
- `@hotwired/stimulus` 
- `@rails/actioncable`

These should already be available in your Rails application.

## Troubleshooting

1. **Controller not registering**: Check the browser console for error messages
2. **Import errors**: Ensure your app has Stimulus and ActionCable properly configured
3. **Asset not found**: Make sure the engine's assets are being precompiled correctly

The engine includes comprehensive fallback logic to work across different setups, so most integration issues are automatically resolved.
