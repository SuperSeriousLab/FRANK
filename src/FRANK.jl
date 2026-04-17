module FRANK

using JSON3, Dates

export FrankEvent, FrankEmitter, emit!, configure!
export EventType
export SubscriptionID, subscribe, unsubscribe!

"""FRANK v0.2 — debug protocol for AI-agent-friendly diagnostics.
Transport: stderr JSONL. One event per line. Agent reads `2>frank.jsonl`.
v0.2 adds subscribe/unsubscribe! fanout for agent attach."""

@enum EventType begin
    STATE_TRANSITION
    INTENT_PARSE
    CONFIDENCE_SCORE
    ACTION_CANDIDATES
    EXECUTION
    CORRECTION
    ERROR
    IDLE_TICK
end

struct ActionCandidate
    cmd::String
    score::Float64
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
function FrankEmitter(; io::IO=stderr, enabled::Bool=true)
    FrankEmitter(io, enabled, STATE_TRANSITION,
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

    evt = FrankEvent(1, now(), component, event_type, state, transition)
    line = JSON3.write(evt)
    println(emitter.io, line)
    flush(emitter.io)

    # Fanout to subscribers (IO write happens first, always)
    if !isempty(emitter.subscribers)
        event_dict = Dict{String,Any}(
            "component"  => component,
            "event_type" => string(event_type),
            "state"      => state,
            "transition" => transition,
            "timestamp"  => time(),
        )
        lock(emitter.subs_lock) do
            for (_, filter_fn, callback) in emitter.subscribers
                try
                    filter_fn(component, event_type, state) && callback(event_dict)
                catch e
                    @warn "FRANK subscriber callback errored" exception=e
                end
            end
        end
    end

    return evt
end

"""Enable/disable FRANK emission at runtime."""
function configure!(emitter::FrankEmitter; enabled::Union{Bool,Nothing}=nothing,
                    io::Union{IO,Nothing}=nothing)
    !isnothing(enabled) && (emitter.enabled = enabled)
    !isnothing(io) && (emitter.io = io)
    return emitter
end

end # module
