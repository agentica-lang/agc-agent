import Stop from "../src/stop_reason"

def test_known_anthropic_reasons() -> Result[Void]
  try Test.eq(Stop.from_anthropic("tool_use"), Stop.StopReason.ToolUse)
  Test.eq(Stop.from_anthropic("refusal"), Stop.StopReason.Refusal)
end

def test_unknown_reason_keeps_its_name() -> Result[Void]
  Test.eq(Stop.from_anthropic("model_context_window_exceeded"), Stop.StopReason.Other("model_context_window_exceeded"))
end
