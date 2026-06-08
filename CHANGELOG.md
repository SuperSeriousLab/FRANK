# FRANK Changelog

## v1.0.0 — 2026-06-08

First stable release. API is now settled and covered by 207 tests plus the
subscribe/fanout and edge-case suites. **Breaking** major bump — see the
`configure!` → `update!` rename below. (Content is the v0.3.0 work promoted to
1.0.0; no separate 0.3.0 registry release.)

### Runtime config cleanup + working severity filter

- **`configure!` → `update!`** (**breaking**): renamed for nomen-omen clarity — the function patches emitter fields in place. Body rewritten from `!isnothing(x) && (assign)` short-circuit side-effects to explicit `if x !== nothing` blocks. No deprecated alias (pre-1.0, no external callers). Update call sites: `update!(emitter; enabled, io, min_level)`.
- **`min_level` is now live**: `emit!` gates on `emitter.min_level`, dropping events whose `EventType` ranks below the floor before any IO or fanout. Previously a dead struct field that `update!`/`configure!` could not even set.
- **`update!` covers `min_level`**: third keyword added; `FrankEmitter` constructor also accepts `min_level=` (defaults `IDLE_TICK` = emit everything, preserving prior behavior).
- **`EventType` reordered by severity** (ascending: `IDLE_TICK`(0) … `ERROR`(7)): ordinals were categorical, so the `min_level` cutoff filtered by declaration accident rather than importance. **Wire-compatible** — JSON3 serializes the enum by string name, so JSONL output is unchanged; `spec/frank-v0.1.json` enum reordered to match (string set, order cosmetic) with a severity note.

## v0.2.1 — 2026-06-04

- Add `Dates` compat entry (General registry AutoMerge requirement). No code changes.

## v0.2.0 — 2026-04-17

### subscribe/unsubscribe! fanout for agent attach

- **Fanout subscriber model**: `subscribe!(handler_fn)` registers a callback that receives every FRANK event emitted in the current process. Multiple subscribers coexist without interference.
- **`unsubscribe!(handler_fn)`**: removes a previously registered handler by identity.
- **Agent attach pattern**: TeleTUI uses this API to route session-scoped events to attached agents — each agent attaches its own subscriber and sees the full event stream filtered by `session_id`.
- **Thread safety**: subscriber list is protected; concurrent attach/detach is safe.
- **TeleTUI event schema** (`spec/teletui-events-v0.1.json`): formal schema for TeleTUI-specific FRANK event types emitted by TeleTUI's FRANK extension — `session_create`, `session_close`, `input_received`, `diff_emitted`, `snapshot_sent`, `auth.ok`, `auth.reject`.
- **Zero overhead when no subscribers**: emit path skips serialization if subscriber list is empty.

### v0.1.0 — initial extraction

- Core FRANK debug protocol: structured JSONL on stderr.
- `emit(event_type, payload)` — fire-and-forget, never raises.
- Timestamp, source, level fields on every event.
- Zero dependencies beyond Julia stdlib + JSON3.
