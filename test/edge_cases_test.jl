using Test
using FRANK
using FRANK: STATE_TRANSITION, INTENT_PARSE, CONFIDENCE_SCORE, ACTION_CANDIDATES,
             EXECUTION, CORRECTION, ERROR, IDLE_TICK
using JSON3
using Dates

@testset "FRANK Edge Cases — Subscribe/Fanout" begin

    # ─────────────────────────────────────────────────────────────────────
    # Edge case 1: Subscriber callback throws exception
    # → emit! continues, logs warning, other subscribers called
    # ─────────────────────────────────────────────────────────────────────
    @testset "callback exception: emit! continues + other subs called" begin
        buf = IOBuffer()
        e = FrankEmitter(io=buf)

        good_sub1 = []
        good_sub2 = []

        # Three subscribers: first throws, second and third are good
        subscribe(e, (c, et, s) -> true, _ -> error("boom"))
        subscribe(e, (c, et, s) -> true, evt -> push!(good_sub1, evt))
        subscribe(e, (c, et, s) -> true, evt -> push!(good_sub2, evt))

        # emit! should return a FrankEvent even though first subscriber threw
        evt = emit!(e, "test-exc", ERROR, Dict{String,Any}("x" => 1))

        # emit! returned a FrankEvent (not rethrown)
        @test evt isa FrankEvent

        # IO write still happened
        output = String(take!(buf))
        @test contains(output, "test-exc")

        # Both good subscribers were called
        @test length(good_sub1) == 1
        @test length(good_sub2) == 1
        @test good_sub1[1]["state"]["x"] == 1
        @test good_sub2[1]["state"]["x"] == 1
    end

    # ─────────────────────────────────────────────────────────────────────
    # Edge case 2: Many subscribers (100+) → emit! scales linearly
    # ─────────────────────────────────────────────────────────────────────
    @testset "many subscribers (100+) all receive event" begin
        buf = IOBuffer()
        e = FrankEmitter(io=buf)

        n = 150
        counts = fill(0, n)

        for i in 1:n
            subscribe(e, (c, et, s) -> true, _ -> (counts[i] += 1))
        end

        # Single emit — all 150 should fire
        emit!(e, "many", EXECUTION, Dict{String,Any}("test" => true))

        @test all(c -> c == 1, counts)
        @test sum(counts) == n
    end

    # ─────────────────────────────────────────────────────────────────────
    # Edge case 3: unsubscribe! during emit! (thread safety test)
    # ─────────────────────────────────────────────────────────────────────
    @testset "unsubscribe during concurrent emit (thread safety)" begin
        buf = IOBuffer()
        e = FrankEmitter(io=buf)

        # Create subscription IDs to unsubscribe later
        sids = []
        for i in 1:20
            sid = subscribe(e, (c, et, s) -> true, _ -> nothing)
            push!(sids, sid)
        end

        # Spawn concurrent emits and unsubscribes
        tasks = []

        # 10 tasks emitting
        for i in 1:10
            t = @async emit!(e, "concurrent-$i", EXECUTION, Dict{String,Any}())
            push!(tasks, t)
        end

        # 10 tasks unsubscribing
        for (i, sid) in enumerate(sids[1:10])
            t = @async unsubscribe!(e, sid)
            push!(tasks, t)
        end

        # Wait for all
        foreach(wait, tasks)

        # Verify: remaining subs should be sids[11:20]
        # All emits should have completed without errors
        @test true  # If we reach here, thread safety held

        # Verify unsubscribe worked (second unsubscribe returns false)
        @test unsubscribe!(e, sids[1]) == false
        @test unsubscribe!(e, sids[11]) == true
    end

    # ─────────────────────────────────────────────────────────────────────
    # Edge case 4: Subscribe with same filter twice
    # → both invoked on match
    # ─────────────────────────────────────────────────────────────────────
    @testset "same filter subscribed twice: both invoked" begin
        buf = IOBuffer()
        e = FrankEmitter(io=buf)

        received = []
        filter_fn = (c, et, s) -> et == ERROR

        sid1 = subscribe(e, filter_fn, evt -> push!(received, :first))
        sid2 = subscribe(e, filter_fn, evt -> push!(received, :second))

        # Error event passes both filters
        emit!(e, "test", ERROR, Dict{String,Any}())

        @test received == [:first, :second]

        # Non-error does not match either
        received_before = length(received)
        emit!(e, "test", IDLE_TICK, Dict{String,Any}())
        @test length(received) == received_before  # No new entries
    end

    # ─────────────────────────────────────────────────────────────────────
    # Edge case 5: Unsubscribed SubscriptionID not recycled to another
    # → rand(UInt64) collision probability negligible, verify structure
    # ─────────────────────────────────────────────────────────────────────
    @testset "unsubscribed SID not recycled (UInt64 space large)" begin
        buf = IOBuffer()
        e = FrankEmitter(io=buf)

        received_first = []
        received_second = []

        sid1 = subscribe(e, (c, et, s) -> true, evt -> push!(received_first, evt))
        emit!(e, "before", IDLE_TICK, Dict{String,Any}())
        @test length(received_first) == 1

        # Unsubscribe first subscriber
        @test unsubscribe!(e, sid1) == true

        # Create new subscriber
        sid2 = subscribe(e, (c, et, s) -> true, evt -> push!(received_second, evt))

        # Emit — only second subscriber receives
        emit!(e, "after", IDLE_TICK, Dict{String,Any}())

        @test length(received_first) == 1  # Still 1 (no new events)
        @test length(received_second) == 1

        # SubscriptionIDs should be different (very high probability)
        @test sid1.id != sid2.id
    end

    # ─────────────────────────────────────────────────────────────────────
    # Edge case 6: Disabled FrankEmitter (enabled=false)
    # → no IO write AND no fanout
    # ─────────────────────────────────────────────────────────────────────
    @testset "disabled emitter: no IO AND no fanout" begin
        buf = IOBuffer()
        e = FrankEmitter(io=buf, enabled=false)

        received = []
        subscribe(e, (c, et, s) -> true, evt -> push!(received, evt))

        result = emit!(e, "ghost", STATE_TRANSITION, Dict{String,Any}())

        @test result === nothing  # returns nothing when disabled
        @test isempty(take!(buf))  # no IO
        @test isempty(received)  # no fanout
    end

    # ─────────────────────────────────────────────────────────────────────
    # Edge case 7: FrankEmitter with IO=devnull
    # → no errors, no output, fanout still works
    # ─────────────────────────────────────────────────────────────────────
    @testset "IO=devnull: no errors, fanout works" begin
        e = FrankEmitter(io=devnull)

        received = []
        subscribe(e, (c, et, s) -> true, evt -> push!(received, evt))

        # Should not error even though writing to devnull
        evt = emit!(e, "devnull-test", CONFIDENCE_SCORE,
                   Dict{String,Any}("score" => 0.95))

        @test evt isa FrankEvent
        @test length(received) == 1
        @test received[1]["state"]["score"] == 0.95
    end

    # ─────────────────────────────────────────────────────────────────────
    # Edge case 8: subscribe before any emit
    # → no stray callbacks (subscriber doesn't fire retroactively)
    # ─────────────────────────────────────────────────────────────────────
    @testset "subscribe before emit: no retroactive callbacks" begin
        buf = IOBuffer()
        e = FrankEmitter(io=buf)

        received = []

        # Subscribe, but no emit has happened yet
        subscribe(e, (c, et, s) -> true, evt -> push!(received, evt))

        # No events received yet
        @test isempty(received)

        # Now emit
        emit!(e, "first", IDLE_TICK, Dict{String,Any}())
        @test length(received) == 1
    end

    # ─────────────────────────────────────────────────────────────────────
    # Edge case 9: emit! after IO closed
    # → graceful error, not crash
    # ─────────────────────────────────────────────────────────────────────
    @testset "emit after IO closed: graceful (shows error)" begin
        buf = IOBuffer()
        e = FrankEmitter(io=buf)

        # Close the buffer
        close(buf)

        # Trying to emit to a closed IO should raise an error
        # (this is expected behavior — not a silent failure)
        error_raised = false
        try
            emit!(e, "closed", IDLE_TICK, Dict{String,Any}())
        catch ex
            # Expected: some kind of IO error
            error_raised = true
        end
        @test error_raised
    end

end

@testset "FRANK Edge Cases — Filter and State" begin

    # ─────────────────────────────────────────────────────────────────────
    # Edge case 10: Filter function rejects by component
    # ─────────────────────────────────────────────────────────────────────
    @testset "filter by component name" begin
        buf = IOBuffer()
        e = FrankEmitter(io=buf)

        received = []
        subscribe(e, (c, et, s) -> c == "target-comp",
                 evt -> push!(received, evt))

        emit!(e, "target-comp", IDLE_TICK, Dict{String,Any}())
        emit!(e, "other-comp", IDLE_TICK, Dict{String,Any}())
        emit!(e, "target-comp", ERROR, Dict{String,Any}())

        @test length(received) == 2
        @test all(e -> e["component"] == "target-comp", received)
    end

    # ─────────────────────────────────────────────────────────────────────
    # Edge case 11: Filter by state content (e.g. "status" key)
    # ─────────────────────────────────────────────────────────────────────
    @testset "filter by state content" begin
        buf = IOBuffer()
        e = FrankEmitter(io=buf)

        received = []
        # Only match events where state has "priority" == "high"
        subscribe(e, (c, et, s) -> haskey(s, "priority") && s["priority"] == "high",
                 evt -> push!(received, evt))

        emit!(e, "a", EXECUTION, Dict{String,Any}("priority" => "high"))
        emit!(e, "b", EXECUTION, Dict{String,Any}("priority" => "low"))
        emit!(e, "c", EXECUTION, Dict{String,Any}())
        emit!(e, "d", EXECUTION, Dict{String,Any}("priority" => "high", "id" => 99))

        @test length(received) == 2
        @test all(e -> e["state"]["priority"] == "high", received)
    end

    # ─────────────────────────────────────────────────────────────────────
    # Edge case 12: Filter always false → no calls
    # ─────────────────────────────────────────────────────────────────────
    @testset "filter always false: never calls callback" begin
        buf = IOBuffer()
        e = FrankEmitter(io=buf)

        received = []
        subscribe(e, (c, et, s) -> false, evt -> push!(received, evt))

        for i in 1:10
            emit!(e, "test", IDLE_TICK, Dict{String,Any}())
        end

        @test isempty(received)
    end

    # ─────────────────────────────────────────────────────────────────────
    # Edge case 13: Filter always true → all calls
    # ─────────────────────────────────────────────────────────────────────
    @testset "filter always true: calls for all events" begin
        buf = IOBuffer()
        e = FrankEmitter(io=buf)

        received = []
        subscribe(e, (c, et, s) -> true, evt -> push!(received, evt))

        for i in 1:10
            emit!(e, "test-$i", IDLE_TICK, Dict{String,Any}())
        end

        @test length(received) == 10
    end

end

@testset "FRANK Edge Cases — Event dict content" begin

    # ─────────────────────────────────────────────────────────────────────
    # Edge case 14: Event dict passed to callback is clean (not raw state)
    # ─────────────────────────────────────────────────────────────────────
    @testset "event dict structure is correct (not identical to state)" begin
        buf = IOBuffer()
        e = FrankEmitter(io=buf)

        received = []
        subscribe(e, (c, et, s) -> true, evt -> push!(received, evt))

        state = Dict{String,Any}("x" => 1)
        emit!(e, "comp", STATE_TRANSITION, state; transition="a->b")

        @test length(received) == 1
        evt = received[1]

        # Event dict has these keys:
        @test haskey(evt, "component")
        @test haskey(evt, "event_type")
        @test haskey(evt, "state")
        @test haskey(evt, "transition")
        @test haskey(evt, "timestamp")

        @test evt["component"] == "comp"
        @test evt["event_type"] == "STATE_TRANSITION"
        @test evt["state"]["x"] == 1
        @test evt["transition"] == "a->b"
    end

    # ─────────────────────────────────────────────────────────────────────
    # Edge case 15: Mutating state after emit does not affect fanout
    # (state is copied, not referenced)
    # ─────────────────────────────────────────────────────────────────────
    @testset "state is immutable to callback (no shared mutation)" begin
        buf = IOBuffer()
        e = FrankEmitter(io=buf)

        received = []
        subscribe(e, (c, et, s) -> true, evt -> push!(received, evt))

        state = Dict{String,Any}("value" => 42)
        emit!(e, "test", EXECUTION, state)

        # Mutate the original state
        state["value"] = 99
        state["new_key"] = "added"

        # Callback received copy, unaffected
        @test received[1]["state"]["value"] == 42
        @test !haskey(received[1]["state"], "new_key")
    end

end

@testset "FRANK Edge Cases — Configuration" begin

    # ─────────────────────────────────────────────────────────────────────
    # Edge case 16: update! with both enabled and io
    # ─────────────────────────────────────────────────────────────────────
    @testset "update! both enabled and io simultaneously" begin
        buf1 = IOBuffer()
        buf2 = IOBuffer()
        e = FrankEmitter(io=buf1)

        # Change both at once
        update!(e; enabled=false, io=buf2)

        @test e.enabled == false
        @test e.io === buf2

        # Emit should be disabled, so buf2 stays empty
        emit!(e, "test", IDLE_TICK, Dict{String,Any}())
        @test length(take!(buf2)) == 0
    end

    # ─────────────────────────────────────────────────────────────────────
    # Edge case 17: update! with only enabled (io stays same)
    # ─────────────────────────────────────────────────────────────────────
    @testset "update! only enabled preserves io" begin
        buf = IOBuffer()
        e = FrankEmitter(io=buf)

        update!(e; enabled=false)
        @test e.io === buf  # IO unchanged

        update!(e; enabled=true)
        @test e.io === buf  # IO still same
    end

    # ─────────────────────────────────────────────────────────────────────
    # Edge case 18: update! with only io (enabled stays same)
    # ─────────────────────────────────────────────────────────────────────
    @testset "update! only io preserves enabled" begin
        buf1 = IOBuffer()
        buf2 = IOBuffer()
        e = FrankEmitter(io=buf1, enabled=false)

        update!(e; io=buf2)
        @test e.enabled == false  # enabled unchanged
        @test e.io === buf2
    end

    # ─────────────────────────────────────────────────────────────────────
    # Edge case 19: min_level gates emit! by enum ordinal
    # ─────────────────────────────────────────────────────────────────────
    @testset "min_level gates emit! output" begin
        buf = IOBuffer()
        e = FrankEmitter(io=buf, enabled=true)

        # Default threshold (IDLE_TICK=0, lowest severity): everything passes.
        @test emit!(e, "c", STATE_TRANSITION, Dict{String,Any}()) !== nothing
        @test emit!(e, "c", IDLE_TICK, Dict{String,Any}()) !== nothing

        # Raise threshold above STATE_TRANSITION: below-threshold dropped.
        update!(e; min_level=EXECUTION)
        @test e.min_level === EXECUTION
        @test emit!(e, "c", STATE_TRANSITION, Dict{String,Any}()) === nothing  # below
        @test emit!(e, "c", INTENT_PARSE, Dict{String,Any}())    === nothing  # below
        @test emit!(e, "c", EXECUTION, Dict{String,Any}())   !== nothing      # at
        @test emit!(e, "c", ERROR, Dict{String,Any}())       !== nothing      # above

        # Dropped events write nothing to IO.
        buf2 = IOBuffer()
        e2 = FrankEmitter(io=buf2, enabled=true)
        update!(e2; min_level=ERROR)
        emit!(e2, "c", STATE_TRANSITION, Dict{String,Any}())
        @test isempty(String(take!(buf2)))
    end

end
