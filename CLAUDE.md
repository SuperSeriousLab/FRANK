# FRANK — Debug Protocol for AI-Agent TUIs

Stderr JSONL state-change events. Companion protocol for JUI
(http://192.168.14.77:3000/eidos/JUI) — agents attach to inspect
live TUI state, like Chrome DevTools for terminal UIs.

## License
Apache 2.0.

## Integration
FRANK is an optional weak dependency of JUI. JUI works without FRANK;
when FRANK is present, JUI emits events on session/input/diff changes.

## Rules
- Julia only.
- Zero non-stdlib deps in runtime (JSON3 acceptable for event marshaling).
- Schema versioned in spec/.
