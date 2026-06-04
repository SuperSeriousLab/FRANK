# FRANK Changelog

## v0.2.1 — 2026-06-04

- Add `Dates` compat entry (General registry AutoMerge requirement). No code changes.

## v0.2.0 — 2026-04-17

### subscribe/unsubscribe! fanout for agent attach

- **Fanout subscriber model**: `subscribe!(handler_fn)` registers a callback that receives every FRANK event emitted in the current process. Multiple subscribers coexist without interference.
- **`unsubscribe!(handler_fn)`**: removes a previously registered handler by identity.
- **Agent attach pattern**: JUI uses this API to route session-scoped events to attached agents — each agent attaches its own subscriber and sees the full event stream filtered by `session_id`.
- **Thread safety**: subscriber list is protected; concurrent attach/detach is safe.
- **JUI event schema** (`spec/jui-events-v0.1.json`): formal schema for JUI-specific FRANK event types emitted by JUI's FRANK extension — `session_create`, `session_close`, `input_received`, `diff_emitted`, `snapshot_sent`, `auth.ok`, `auth.reject`.
- **Zero overhead when no subscribers**: emit path skips serialization if subscriber list is empty.

### v0.1.0 — initial extraction

- Core FRANK debug protocol: structured JSONL on stderr.
- `emit(event_type, payload)` — fire-and-forget, never raises.
- Timestamp, source, level fields on every event.
- Zero dependencies beyond Julia stdlib + JSON3.
