# FRANK — Debug Protocol for AI-Agent-Friendly Julia Applications

FRANK is a lightweight structured event protocol for Julia applications.
It emits JSONL on stderr — one event per line — giving AI agents, debuggers,
and logging pipelines a machine-readable window into running application state.

Think of it as Chrome DevTools for your Julia app: structured, subscribable,
zero-overhead when disabled.

## Features

- **Structured JSONL on stderr** — every event has `frank_v`, `ts`, `component`, `event_type`, `state`
- **Fanout subscriber model** — multiple agents can attach; each gets every event
- **`subscribe` / `unsubscribe!`** — register callbacks by identity, thread-safe
- **Zero overhead when idle** — emit path skips serialization if subscriber list is empty
- **Never raises** — all emit paths are fire-and-forget; errors are swallowed silently

## Install

```julia
using Pkg
Pkg.Registry.add(Pkg.RegistrySpec(url="https://github.com/SuperSeriousLab/JuliaRegistry.git"))
Pkg.add("FRANK")
```

## Quick Start

```julia
using FRANK, Dates

emitter = FrankEmitter(stderr, true, STATE_TRANSITION)

# Subscribe an agent handler
id = subscribe(emitter) do event
    println("Agent sees: ", event.event_type, " from ", event.component)
end

# Emit an event
emit!(emitter, "my_component", STATE_TRANSITION, Dict("key" => "value"))

# Detach
unsubscribe!(emitter, id)
```

## Event Schema

Every FRANK event:

```json
{
  "frank_v": 2,
  "ts": "2026-04-19T10:00:00.000",
  "component": "my_component",
  "event_type": "STATE_TRANSITION",
  "state": { "key": "value" },
  "transition": null
}
```

JUI-specific event types (emitted by `JUI` when `FRANK` is loaded) are defined in
`spec/jui-events-v0.1.json`.

## Agent Attach Pattern

```julia
using FRANK

emitter = FrankEmitter(stderr, true, STATE_TRANSITION)
session_id = "abc123"

sub_id = subscribe(emitter) do event
    if get(event.state, "session_id", "") == session_id
        # handle session-scoped event
    end
end

# ... when agent detaches:
unsubscribe!(emitter, sub_id)
```

## Consuming FRANK Output

Redirect stderr to a file and tail it:

```bash
julia myapp.jl 2>frank.jsonl &
tail -f frank.jsonl | jq .
```

Or pipe to a log processor:

```bash
julia myapp.jl 2>&1 1>/dev/null | jq 'select(.event_type == "ERROR")'
```

## Integration with JUI

FRANK is an optional weak dependency of [JUI](https://github.com/SuperSeriousLab/JUI).
When both packages are loaded, JUI automatically emits session lifecycle events
(`session_create`, `session_close`, `input_received`, `diff_emitted`,
`snapshot_sent`, `auth.ok`, `auth.reject`) through FRANK.

```julia
using JUI, FRANK
# FRANK events now flow automatically
```

## License

MIT License. See [LICENSE](LICENSE).
