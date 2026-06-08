using Test
using FRANK
using FRANK: STATE_TRANSITION, INTENT_PARSE, CONFIDENCE_SCORE, ACTION_CANDIDATES,
             EXECUTION, CORRECTION, ERROR, IDLE_TICK
using JSON3
using Dates
using Random

@testset "FRANK Debug Protocol" begin

    # ---------------------------------------------------------------
    # 1. FrankEmitter construction
    # ---------------------------------------------------------------
    @testset "FrankEmitter construction" begin
        @testset "default (stderr)" begin
            e = FrankEmitter()
            @test e.io === stderr
            @test e.enabled == true
        end

        @testset "custom IO" begin
            buf = IOBuffer()
            e = FrankEmitter(io=buf)
            @test e.io === buf
            @test e.enabled == true
        end

        @testset "disabled at construction" begin
            e = FrankEmitter(enabled=false)
            @test e.enabled == false
        end

        @testset "custom IO + disabled" begin
            buf = IOBuffer()
            e = FrankEmitter(io=buf, enabled=false)
            @test e.io === buf
            @test e.enabled == false
        end
    end

    # ---------------------------------------------------------------
    # 2. Event emission — valid JSONL, one line, correct fields
    # ---------------------------------------------------------------
    @testset "Event emission basics" begin
        buf = IOBuffer()
        e = FrankEmitter(io=buf)

        evt = emit!(e, "test-component", STATE_TRANSITION,
                    Dict{String,Any}("key" => "value");
                    transition="a->b")

        output = String(take!(buf))
        lines = split(strip(output), "\n")
        @test length(lines) == 1

        parsed = JSON3.read(lines[1], Dict{String,Any})
        @test parsed["frank_v"] == 1
        @test parsed["component"] == "test-component"
        @test parsed["transition"] == "a->b"
        @test haskey(parsed, "ts")
        @test haskey(parsed, "event_type")
        @test haskey(parsed, "state")
        @test parsed["state"]["key"] == "value"

        # Return value is a FrankEvent
        @test evt isa FrankEvent
        @test evt.frank_v == 1
        @test evt.component == "test-component"
    end

    @testset "Multiple emissions produce multiple lines" begin
        buf = IOBuffer()
        e = FrankEmitter(io=buf)

        emit!(e, "a", STATE_TRANSITION, Dict{String,Any}())
        emit!(e, "b", ERROR, Dict{String,Any}("x" => 1))
        emit!(e, "c", IDLE_TICK, Dict{String,Any}())

        output = String(take!(buf))
        lines = filter(!isempty, split(output, "\n"))
        @test length(lines) == 3

        # Each line is valid JSON
        for line in lines
            parsed = JSON3.read(line, Dict{String,Any})
            @test parsed["frank_v"] == 1
        end
    end

    # ---------------------------------------------------------------
    # 3. All EventType values emit correctly
    # ---------------------------------------------------------------
    @testset "All EventType values" begin
        all_types = instances(EventType)
        @test length(collect(all_types)) == 8  # verify we know all of them

        for et in all_types
            buf = IOBuffer()
            e = FrankEmitter(io=buf)
            evt = emit!(e, "type-test", et, Dict{String,Any}("et" => string(et)))

            @test evt isa FrankEvent
            @test evt.event_type == et

            output = String(take!(buf))
            parsed = JSON3.read(strip(output), Dict{String,Any})
            @test haskey(parsed, "event_type")
        end
    end

    # ---------------------------------------------------------------
    # 4. JSON serialization roundtrip
    # ---------------------------------------------------------------
    @testset "JSON serialization roundtrip" begin
        buf = IOBuffer()
        e = FrankEmitter(io=buf)

        state = Dict{String,Any}("count" => 42, "flag" => true, "name" => "test")
        emit!(e, "roundtrip", CONFIDENCE_SCORE, state; transition="idle->active")

        output = String(take!(buf))
        parsed = JSON3.read(strip(output), Dict{String,Any})

        @test parsed["frank_v"] === 1
        @test parsed["component"] == "roundtrip"
        @test parsed["transition"] == "idle->active"
        @test parsed["state"]["count"] == 42
        @test parsed["state"]["flag"] == true
        @test parsed["state"]["name"] == "test"

        # frank_v is always 1
        @test parsed["frank_v"] == 1

        # ts is valid ISO datetime
        ts_str = parsed["ts"]
        @test ts_str isa String
        dt = DateTime(ts_str, dateformat"yyyy-mm-ddTHH:MM:SS.sss")
        @test dt isa DateTime
        @test year(dt) >= 2024
    end

    # ---------------------------------------------------------------
    # 5. Disabled emitter produces NO output
    # ---------------------------------------------------------------
    @testset "Disabled emitter" begin
        buf = IOBuffer()
        e = FrankEmitter(io=buf, enabled=false)

        result = emit!(e, "ghost", STATE_TRANSITION,
                       Dict{String,Any}("should" => "not appear"))

        @test result === nothing
        @test length(take!(buf)) == 0
    end

    # ---------------------------------------------------------------
    # 6. update! — toggle enabled, change IO
    # ---------------------------------------------------------------
    @testset "update!" begin
        buf1 = IOBuffer()
        buf2 = IOBuffer()
        e = FrankEmitter(io=buf1)

        # Disable at runtime
        update!(e; enabled=false)
        @test e.enabled == false
        emit!(e, "x", ERROR, Dict{String,Any}())
        @test length(take!(buf1)) == 0

        # Re-enable
        update!(e; enabled=true)
        @test e.enabled == true
        emit!(e, "x", ERROR, Dict{String,Any}("alive" => true))
        @test length(take!(buf1)) > 0

        # Change IO target
        update!(e; io=buf2)
        @test e.io === buf2
        emit!(e, "x", IDLE_TICK, Dict{String,Any}("target" => "buf2"))
        @test length(take!(buf1)) == 0  # nothing new in buf1
        output2 = String(take!(buf2))
        @test contains(output2, "buf2")

        # update! returns the emitter
        ret = update!(e; enabled=false)
        @test ret === e
    end

    # ---------------------------------------------------------------
    # 7. Concurrent emission — no corruption
    # ---------------------------------------------------------------
    @testset "Concurrent emission" begin
        buf = IOBuffer()
        e = FrankEmitter(io=buf)
        n = 50

        tasks = map(1:n) do i
            @async emit!(e, "concurrent-$i", EXECUTION,
                         Dict{String,Any}("i" => i))
        end
        foreach(wait, tasks)

        output = String(take!(buf))
        lines = filter(!isempty, split(output, "\n"))
        @test length(lines) == n

        # Each line must parse as valid JSON
        for (idx, line) in enumerate(lines)
            parsed = JSON3.read(line, Dict{String,Any})
            @test parsed["frank_v"] == 1
            @test startswith(parsed["component"], "concurrent-")
        end
    end

    # ---------------------------------------------------------------
    # 8. Empty state dict
    # ---------------------------------------------------------------
    @testset "Empty state dict" begin
        buf = IOBuffer()
        e = FrankEmitter(io=buf)

        evt = emit!(e, "empty", IDLE_TICK, Dict{String,Any}())

        output = String(take!(buf))
        parsed = JSON3.read(strip(output), Dict{String,Any})
        @test parsed["state"] isa Dict || parsed["state"] isa JSON3.Object
        @test length(parsed["state"]) == 0
    end

    # ---------------------------------------------------------------
    # 9. Large state dict — 100+ keys, nested, arrays
    # ---------------------------------------------------------------
    @testset "Large state dict" begin
        buf = IOBuffer()
        e = FrankEmitter(io=buf)

        big_state = Dict{String,Any}()
        for i in 1:150
            big_state["key_$i"] = i
        end
        big_state["nested"] = Dict{String,Any}(
            "level1" => Dict{String,Any}(
                "level2" => Dict{String,Any}("deep" => "value")
            )
        )
        big_state["array"] = [1, 2, 3, "four", Dict{String,Any}("five" => 5)]
        big_state["mixed_array"] = Any[true, false, nothing, 3.14, "str"]

        emit!(e, "large", STATE_TRANSITION, big_state)

        output = String(take!(buf))
        lines = filter(!isempty, split(output, "\n"))
        @test length(lines) == 1  # still single line

        parsed = JSON3.read(strip(output), Dict{String,Any})
        @test parsed["state"]["key_1"] == 1
        @test parsed["state"]["key_150"] == 150
        # nested access
        nested = parsed["state"]["nested"]
        @test nested["level1"]["level2"]["deep"] == "value"
        # array
        arr = parsed["state"]["array"]
        @test length(arr) == 5
    end

    # ---------------------------------------------------------------
    # 10. Special characters in state
    # ---------------------------------------------------------------
    @testset "Special characters in state" begin
        buf = IOBuffer()
        e = FrankEmitter(io=buf)

        state = Dict{String,Any}(
            "newlines"    => "line1\nline2\nline3",
            "quotes"      => "she said \"hello\"",
            "backslashes" => "path\\to\\file",
            "unicode"     => "cafe\u0301 \u2603 \U0001F680",
            "tabs"        => "col1\tcol2\tcol3",
            "null_char"   => "before\0after",
            "emoji"       => "\U0001F4A9\U0001F525",
        )

        emit!(e, "special", INTENT_PARSE, state)

        output = String(take!(buf))
        lines = filter(!isempty, split(output, "\n"))
        # Even with newlines in values, it should be a single JSONL line
        # because JSON encodes newlines as \n escape sequences
        parsed = JSON3.read(lines[1], Dict{String,Any})
        @test contains(parsed["state"]["newlines"], "line1")
        @test contains(parsed["state"]["quotes"], "hello")
        @test contains(parsed["state"]["backslashes"], "\\")
        @test contains(parsed["state"]["unicode"], "\u2603")
    end

    # ---------------------------------------------------------------
    # 11. Null transition
    # ---------------------------------------------------------------
    @testset "Null transition" begin
        buf = IOBuffer()
        e = FrankEmitter(io=buf)

        # Default transition is nothing
        emit!(e, "null-trans", CORRECTION, Dict{String,Any}("x" => 1))

        output = String(take!(buf))
        parsed = JSON3.read(strip(output), Dict{String,Any})
        @test parsed["transition"] === nothing

        # Explicit nothing
        emit!(e, "null-trans2", ERROR, Dict{String,Any}();
              transition=nothing)

        output2 = String(take!(buf))
        parsed2 = JSON3.read(strip(output2), Dict{String,Any})
        @test parsed2["transition"] === nothing
    end

    # ---------------------------------------------------------------
    # 12. IO flush — events appear immediately
    # ---------------------------------------------------------------
    @testset "IO flush" begin
        buf = IOBuffer()
        e = FrankEmitter(io=buf)

        emit!(e, "flush-test", ACTION_CANDIDATES,
              Dict{String,Any}("cmd" => "ls", "score" => 0.95))

        # Data should be available immediately without manual flush
        available = bytesavailable(buf)
        seekstart(buf)
        data = read(buf, String)
        @test length(data) > 0
        @test contains(data, "flush-test")
    end

    # ---------------------------------------------------------------
    # Additional edge cases
    # ---------------------------------------------------------------
    @testset "frank_v is always 1 across many events" begin
        buf = IOBuffer()
        e = FrankEmitter(io=buf)

        for _ in 1:20
            emit!(e, "v-check", IDLE_TICK, Dict{String,Any}())
        end

        output = String(take!(buf))
        for line in filter(!isempty, split(output, "\n"))
            parsed = JSON3.read(line, Dict{String,Any})
            @test parsed["frank_v"] === 1
        end
    end

    @testset "ts advances or stays same across sequential events" begin
        buf = IOBuffer()
        e = FrankEmitter(io=buf)

        emit!(e, "time1", IDLE_TICK, Dict{String,Any}())
        emit!(e, "time2", IDLE_TICK, Dict{String,Any}())

        output = String(take!(buf))
        lines = filter(!isempty, split(output, "\n"))
        ts1 = JSON3.read(lines[1], Dict{String,Any})["ts"]
        ts2 = JSON3.read(lines[2], Dict{String,Any})["ts"]
        dt1 = DateTime(ts1, dateformat"yyyy-mm-ddTHH:MM:SS.sss")
        dt2 = DateTime(ts2, dateformat"yyyy-mm-ddTHH:MM:SS.sss")
        @test dt2 >= dt1
    end

    @testset "Transition with string value" begin
        buf = IOBuffer()
        e = FrankEmitter(io=buf)

        emit!(e, "trans", STATE_TRANSITION,
              Dict{String,Any}(); transition="boot->ready")

        output = String(take!(buf))
        parsed = JSON3.read(strip(output), Dict{String,Any})
        @test parsed["transition"] == "boot->ready"
    end

    @testset "Component can be empty string" begin
        buf = IOBuffer()
        e = FrankEmitter(io=buf)

        evt = emit!(e, "", IDLE_TICK, Dict{String,Any}())
        @test evt.component == ""

        output = String(take!(buf))
        parsed = JSON3.read(strip(output), Dict{String,Any})
        @test parsed["component"] == ""
    end
end

# ---------------------------------------------------------------
# Subscribe / unsubscribe! / fanout (v0.2 API)
# ---------------------------------------------------------------
@testset "FRANK subscribe/unsubscribe!/fanout" begin

    # ── subscribe → callback invoked ────────────────────────────
    @testset "subscribe + emit → callback invoked" begin
        buf = IOBuffer()
        e = FrankEmitter(io=buf)
        received = []

        sid = subscribe(e, (c, et, s) -> true, evt -> push!(received, evt))
        emit!(e, "comp", STATE_TRANSITION, Dict{String,Any}("x" => 1))

        @test length(received) == 1
        @test received[1]["component"] == "comp"
        @test received[1]["event_type"] == "STATE_TRANSITION"
        @test received[1]["state"]["x"] == 1
    end

    # ── filter_fn rejects → callback NOT invoked ────────────────
    @testset "filter_fn rejects → callback not invoked" begin
        buf = IOBuffer()
        e = FrankEmitter(io=buf)
        received = []

        # Only accept ERROR events
        subscribe(e, (c, et, s) -> et == ERROR, evt -> push!(received, evt))
        emit!(e, "comp", STATE_TRANSITION, Dict{String,Any}())
        emit!(e, "comp", IDLE_TICK, Dict{String,Any}())

        @test isempty(received)

        # Now emit an ERROR — should arrive
        emit!(e, "comp", ERROR, Dict{String,Any}("err" => "boom"))
        @test length(received) == 1
        @test received[1]["event_type"] == "ERROR"
    end

    # ── unsubscribe → no more calls ─────────────────────────────
    @testset "unsubscribe! → no more calls" begin
        buf = IOBuffer()
        e = FrankEmitter(io=buf)
        received = []

        sid = subscribe(e, (c, et, s) -> true, evt -> push!(received, evt))
        emit!(e, "a", STATE_TRANSITION, Dict{String,Any}())
        @test length(received) == 1

        result = unsubscribe!(e, sid)
        @test result == true

        emit!(e, "b", STATE_TRANSITION, Dict{String,Any}())
        @test length(received) == 1  # still 1, no new delivery
    end

    # ── double unsubscribe → second call returns false ──────────
    @testset "double unsubscribe! returns false" begin
        buf = IOBuffer()
        e = FrankEmitter(io=buf)

        sid = subscribe(e, (c, et, s) -> true, _ -> nothing)
        @test unsubscribe!(e, sid) == true
        @test unsubscribe!(e, sid) == false
    end

    # ── multiple subscribers each get called ────────────────────
    @testset "multiple subscribers all receive event" begin
        buf = IOBuffer()
        e = FrankEmitter(io=buf)
        counts = [0, 0, 0]

        subscribe(e, (c, et, s) -> true, _ -> (counts[1] += 1))
        subscribe(e, (c, et, s) -> true, _ -> (counts[2] += 1))
        subscribe(e, (c, et, s) -> true, _ -> (counts[3] += 1))

        emit!(e, "multi", EXECUTION, Dict{String,Any}())

        @test counts == [1, 1, 1]
    end

    # ── callback throwing does NOT break emit! ───────────────────
    @testset "throwing callback does not break emit!" begin
        buf = IOBuffer()
        e = FrankEmitter(io=buf)
        good_received = []

        subscribe(e, (c, et, s) -> true, _ -> error("deliberate error"))
        subscribe(e, (c, et, s) -> true, evt -> push!(good_received, evt))

        # emit! must return an event (not rethrow)
        evt = emit!(e, "safe", IDLE_TICK, Dict{String,Any}("k" => "v"))
        @test evt isa FrankEvent

        # IO write still happened
        output = String(take!(buf))
        @test contains(output, "safe")

        # Good subscriber still received
        @test length(good_received) == 1
    end

    # ── SubscriptionID is opaque and unique ─────────────────────
    @testset "SubscriptionID values are distinct" begin
        buf = IOBuffer()
        e = FrankEmitter(io=buf)

        s1 = subscribe(e, (c, et, s) -> true, _ -> nothing)
        s2 = subscribe(e, (c, et, s) -> true, _ -> nothing)
        @test s1 isa SubscriptionID
        @test s2 isa SubscriptionID
        @test s1.id != s2.id
    end

    # ── Thread safety (basic) ────────────────────────────────────
    @testset "thread safety — concurrent emit with subscribers" begin
        buf = IOBuffer()
        e = FrankEmitter(io=buf)
        received = Channel{Dict}(200)

        subscribe(e, (c, et, s) -> true, evt -> put!(received, evt))
        n = 50

        @sync for i in 1:n
            @async emit!(e, "t-$i", EXECUTION, Dict{String,Any}("i" => i))
        end

        close(received)
        count = 0
        for _ in received
            count += 1
        end
        @test count == n

        # IO also got all n lines
        output = String(take!(buf))
        lines = filter(!isempty, split(output, "\n"))
        @test length(lines) == n
    end

    # ── Disabled emitter skips fanout ────────────────────────────
    @testset "disabled emitter — fanout also skipped" begin
        buf = IOBuffer()
        e = FrankEmitter(io=buf, enabled=false)
        received = []

        subscribe(e, (c, et, s) -> true, evt -> push!(received, evt))
        result = emit!(e, "ghost", STATE_TRANSITION, Dict{String,Any}())

        @test result === nothing
        @test isempty(received)
    end

end

# Edge case tests
include("edge_cases_test.jl")
