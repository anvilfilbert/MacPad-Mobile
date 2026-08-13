# Explicit save only

PhonePad writes edited text to its File only when the user invokes Save. Unsaved changes remain visibly marked and are preserved through Document Recovery, but editing, backgrounding, suspension, and termination never silently overwrite the original File; this matches MacPad and avoids committing accidental changes merely because iOS changed app state.
