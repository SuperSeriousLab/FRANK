module FRANK

using JSON3, Dates

export FrankEvent, FrankEmitter, emit!, update!
export EventType
export SubscriptionID, subscribe, unsubscribe!

"""FRANK v1.0 — debug protocol for AI-agent-friendly diagnostics.
Transport: stderr JSONL. One event per line. Agent reads `2>frank.jsonl`.
Subscribe/unsubscribe! fanout for agent attach; `update!` for runtime config;
`min_level` severity gating on `emit!`."""

# Ordered by severity (ascending): ordinal IS the importance rank, so
# `min_level` gating in emit! drops everything below the chosen floor.
# IDLE_TICK = noise (lowest), ERROR = highest. Wire format is the string
# name (JSON3 serializes @enum by name), so this order never leaks to JSONL —
# reordering is wire-compatible.
@enum EventType begin
    IDLE_TICK          # 0 — heartbeat noise
    STATE_TRANSITION   # 1
    INTENT_PARSE       # 2
    CONFIDENCE_SCORE   # 3
    ACTION_CANDIDATES  # 4
    EXECUTION          # 5
    CORRECTION         # 6
    ERROR              # 7 — highest severity
end

struct FrankEvent
    frank_v::Int
    ts::DateTime
    component::String
    event_type::EventType
    state::Dict{String,Any}
    transition::Union{String,Nothing}
end

"""Opaque subscription identifier returned by `subscribe`."""
struct SubscriptionID
    id::UInt64
end

mutable struct FrankEmitter
    io::IO
    enabled::Bool
    min_level::EventType
    subscribers::Vector{Tuple{SubscriptionID,Function,Function}}  # (id, filter_fn, callback)
    subs_lock::ReentrantLock
end

"""Create emitter writing to stderr by default."""
function FrankEmitter(; io::IO=stderr, enabled::Bool=true, min_level::EventType=IDLE_TICK)
    FrankEmitter(io, enabled, min_level,
                 Vector{Tuple{SubscriptionID,Function,Function}}(),
                 ReentrantLock())
end

"""
    subscribe(emitter, filter_fn, callback) → SubscriptionID

Register a subscriber callback. `filter_fn(component, event_type, state) → Bool`
controls which events are delivered. Returns an opaque `SubscriptionID` for
use with `unsubscribe!`. Thread-safe.
"""
function subscribe(emitter::FrankEmitter, filter_fn::Function, callback::Function)
    sid = SubscriptionID(rand(UInt64))
    lock(emitter.subs_lock) do
        push!(emitter.subscribers, (sid, filter_fn, callback))
    end
    return sid
end

"""
    unsubscribe!(emitter, sid) → Bool

Remove the subscriber identified by `sid`. Returns `true` if found and
removed, `false` if already gone. Thread-safe.
"""
function unsubscribe!(emitter::FrankEmitter, sid::SubscriptionID)
    lock(emitter.subs_lock) do
        idx = findfirst(t -> t[1] == sid, emitter.subscribers)
        idx === nothing && return false
        deleteat!(emitter.subscribers, idx)
        return true
    end
end

"""Emit a FRANK event as single JSONL line to configured IO, then fan out to subscribers."""
function emit!(emitter::FrankEmitter, component::String, event_type::EventType,
               state::Dict{String,Any}; transition::Union{String,Nothing}=nothing)
    !emitter.enabled && return nothing
    # Gate on min_level: skip events whose type ranks below the threshold.
    # Ordinal comparison over the @enum; default IDLE_TICK (0) passes all.
    Integer(event_type) < Integer(emitter.min_level) && return nothing

    evt = FrankEvent(1, now(), component, event_type, state, transition)
    line = JSON3.write(evt)
    println(emitter.io, line)
    flush(emitter.io)

    # Fanout to subscribers (IO write happens first, always)
    if !isempty(emitter.subscribers)
        lock(emitter.subs_lock) do
            for (_, filter_fn, callback) in emitter.subscribers
                try
                    if filter_fn(component, event_type, state)
                        # Create fresh event_dict for each subscriber to ensure isolation
                        event_dict = Dict{String,Any}(
                            "component"  => component,
                            "event_type" => string(event_type),
                            "state"      => copy(state),
                            "transition" => transition,
                            "timestamp"  => time(),
                        )
                        callback(event_dict)
                    end
                catch e
                    @warn "FRANK subscriber callback errored" exception=e
                end
            end
        end
    end

    return evt
end

"""
    update!(emitter; enabled, io, min_level) → emitter

Patch emitter settings in place. Each keyword overrides one field; any keyword
left at its `nothing` default keeps the current value. Returns the emitter so
calls chain. Thread-safety note: mutates fields directly — coordinate with
concurrent `emit!` callers if you flip `io` mid-stream.
"""
function update!(emitter::FrankEmitter;
                 enabled::Union{Bool,Nothing}=nothing,
                 io::Union{IO,Nothing}=nothing,
                 min_level::Union{EventType,Nothing}=nothing)
    if enabled !== nothing
        emitter.enabled = enabled
    end
    if io !== nothing
        emitter.io = io
    end
    if min_level !== nothing
        emitter.min_level = min_level
    end
    return emitter
end

end # module
