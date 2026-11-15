## Why a model stopped: the same for every provider. Each provider maps its own reasons to it.
enum StopReason
  EndTurn
  ToolUse
  MaxTokens
  StopSequence
  Refusal
  PauseTurn
  Other(String)
end
