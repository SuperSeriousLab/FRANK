using Test
using FRANK
using FRANK: STATE_TRANSITION, INTENT_PARSE, CONFIDENCE_SCORE, ACTION_CANDIDATES,
             EXECUTION, CORRECTION, ERROR, IDLE_TICK
using JSON3
using Dates

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
    # 6. configure! — toggle enabled, change IO
    # ---------------------------------------------------------------
    @testset "configure!" begin
        buf1 = IOBuffer()
        buf2 = IOBuffer()
        e = FrankEmitter(io=buf1)

        # Disable at runtime
        configure!(e; enabled=false)
        @test e.enabled == false
        emit!(e, "x", ERROR, Dict{String,Any}())
        @test length(take!(buf1)) == 0

        # Re-enable
        configure!(e; enabled=true)
        @test e.enabled == true
        emit!(e, "x", ERROR, Dict{String,Any}("alive" => true))
        @test length(take!(buf1)) > 0

        # Change IO target
        configure!(e; io=buf2)
        @test e.io === buf2
        emit!(e, "x", IDLE_TICK, Dict{String,Any}("target" => "buf2"))
        @test length(take!(buf1)) == 0  # nothing new in buf1
        output2 = String(take!(buf2))
        @test contains(output2, "buf2")

        # configure! returns the emitter
        ret = configure!(e; enabled=false)
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
