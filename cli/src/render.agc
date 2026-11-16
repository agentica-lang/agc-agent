## What the client prints, as text: the events, the approval prompt and the history. Pure.

import Client from "pkg/client/client"
import Protocol from "pkg/protocol/protocol"

ESC = 27
ANSWER_HINT = "allow? y = yes, n = no, a = yes for the session"

## What the output line holds: nothing, or the text or the thinking that streams in pieces.
enum Flow
  Idle
  Text
  Thinking
end

## One piece of output. A `Flow.Idle` piece is whole lines; the other flows stream and stay open until a newline.
struct Out
  text: String
  flow: Flow
  closed: Bool
end

struct Style
  thinking: Bool
  color: Bool
end

## What `put` gives: the text to print, and the flow the output is in after it.
struct Written
  text: String
  flow: Flow
end

def line(text: String) -> Out = Out(text: "#{text}\n", flow: Flow.Idle, closed: true)

## The piece an event prints; none for one that shows nothing (the thinking without `--thinking`, and the events the
## client handles itself).
def event(event: Protocol.Event, style: Style) -> Optional[Out]
  case event
    Protocol.Event.TextDelta(delta) -> some(streamed(delta.text, Flow.Text, delta.text))
    Protocol.Event.ThinkingDelta(delta) -> thinking(delta.text, style)
    Protocol.Event.ToolStarted(tool) -> some(line("[tool] #{tool.name} #{tool.summary}"))
    Protocol.Event.ToolFinished(tool) -> some(line(finished(tool)))
    Protocol.Event.ApprovalResolved(resolved) -> some(line(resolution(resolved)))
    Protocol.Event.Usage(usage) -> some(line(counts(usage)))
    Protocol.Event.TurnFinished(done) -> some(line("[turn finished] #{Protocol.stop_reason_name(done.stop_reason)}"))
    Protocol.Event.Error(failure) -> some(line("[error] #{failure.kind}: #{failure.message}"))
    Protocol.Event.TurnStarted(_) -> none
    Protocol.Event.ApprovalRequested(_) -> none
    Protocol.Event.Resync -> none
    Protocol.Event.MessageQueued(queued) -> some(line("[queued] #{Client.printable(queued.text)}"))
    Protocol.Event.ShellStarted(started) -> some(line(shell_started(started)))
    Protocol.Event.ShellFinished(finished) -> some(line(shell_finished(finished)))
  end
end

def prompt(request: Protocol.ApprovalRequested) -> Out
  head = "[approval #{request.approval_id}] #{request.tool}: #{request.preview}"
  line("#{head}\n#{indented(request.detail)}#{ANSWER_HINT}")
end

## The decision a line of the terminal answers, if it is one.
def answer(text: String) -> Optional[Protocol.Decision]
  case text.strip.downcase
    "y", "yes" -> some(Protocol.Decision.Allow)
    "n", "no" -> some(Protocol.Decision.Deny)
    "a", "always" -> some(Protocol.Decision.AllowSession)
    _ -> none
  end
end

def history(messages: List[Protocol.Message]) -> String
  lines = messages.map do |message| "#{Protocol.role_name(message.role)}: #{message.text}" end

  lines.join("\n")
end

## The text to print for `out` when the output is in `flow`: a newline first when the line is open with another flow.
def put(flow: Flow, out: Out) -> Written
  text = out.text
  if flow != Flow.Idle and flow != out.flow
    text = "\n#{text}"
  end

  return Written(text: text, flow: Flow.Idle) if out.closed

  Written(text: text, flow: out.flow)
end

private

# What the call would write, one indented line at a time, so the user sees what they approve.
def indented(detail: String) -> String
  return "" if detail == ""

  lines = detail.split("\n").map { |text| "  #{text}\n" }
  lines.join("")
end

def streamed(text: String, flow: Flow, shown: String) -> Out
  Out(text: shown, flow: flow, closed: text.end_with?("\n"))
end

def thinking(text: String, style: Style) -> Optional[Out]
  return none if not style.thinking

  some(streamed(text, Flow.Thinking, dimmed(text, style)))
end

def dimmed(text: String, style: Style) -> String
  return text if not style.color

  esc = String.from_code(ESC)
  "#{esc}[2m#{text}#{esc}[0m"
end

def finished(tool: Protocol.ToolFinished) -> String
  return "[tool ok] #{tool.summary} (#{tool.duration_ms} ms)" if tool.ok

  "[tool failed] #{tool.summary} (#{tool.duration_ms} ms)"
end

def shell_started(started: Protocol.ShellStarted) -> String
  return "[shell] #{Client.printable(started.command)}" if started.context

  "[shell] #{Client.printable(started.command)} (not for the model)"
end

# The output one printable line at a time, then whether it worked.
def shell_finished(finished: Protocol.ShellFinished) -> String
  lines = finished.output.split("\n").map { |text| Client.printable(text) }
  if lines.size > 0 and lines.last == ""
    lines = lines.take(lines.size - 1)
  end

  state = "ok"
  if not finished.ok
    state = "failed"
  end

  lines.push("[shell #{state}] (#{finished.duration_ms} ms)").join("\n")
end

def resolution(resolved: Protocol.ApprovalResolved) -> String
  decision = Protocol.decision_name(resolved.decision)
  "[approval #{resolved.approval_id}] #{decision} (#{Protocol.source_name(resolved.source)})"
end

def counts(usage: Protocol.Usage) -> String
  (
    "[usage] input #{usage.input}, output (session) #{usage.output}, cache read #{usage.cache_read}, " +
    "cache write #{usage.cache_write}, context #{usage.context}"
  )
end
