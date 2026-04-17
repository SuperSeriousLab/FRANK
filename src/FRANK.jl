module FRANK

using JSON3, Dates

export FrankEvent, FrankEmitter, emit!, configure!
export EventType

"""FRANK v0.1 — debug protocol for AI-agent-friendly diagnostics.
Transport: stderr JSONL. One event per line. Agent reads `2>frank.jsonl`."""

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

mutable struct FrankEmitter
    io::IO
    enabled::Bool
    min_level::EventType
end

"""Create emitter writing to stderr by default."""
function FrankEmitter(; io::IO=stderr, enabled::Bool=true)
    FrankEmitter(io, enabled, STATE_TRANSITION)
end

"""Emit a FRANK event as single JSONL line to configured IO."""
function emit!(emitter::FrankEmitter, component::String, event_type::EventType,
               state::Dict{String,Any}; transition::Union{String,Nothing}=nothing)
    !emitter.enabled && return nothing

    evt = FrankEvent(1, now(), component, event_type, state, transition)
    line = JSON3.write(evt)
    println(emitter.io, line)
    flush(emitter.io)
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
