## The registry of `Core.serve`, in a server: a prompt after the system prompt, a `Message` handler, and services that
## start in order and stop in the reverse order.

import LLM from "pkg/llm/llm"
import Protocol from "pkg/protocol/protocol"
import Core from "../core"
import Extensions from "../src/config/registry"
import Fake from "support/fake_llm"
import H from "support/harness"

# The model gets the prompt of the extension after the system prompt, and the message as the handler changed it; the
# session keeps what the user typed.
def test_a_prompt_and_a_message_handler_reach_the_model() -> Result[Void]
  registry = (
    Core.registry()
    |> Core.add_prompt("Answer in one line.")
    |> Core.on(Core.Event.Message(->(text: String) { "#{text} (asked in a test)" }))
  )

  H.using(H.Setup(replies: ["text.sse"], registry: some(registry))) do |h|
    id = try H.new_session(h)
    a = try H.subscribe(h, id)
    _ = try H.send(h, id, "Hi.")
    a = try H.until(a, Protocol.EventKind.TurnFinished)
    H.close(a)
    body = (try Fake.next_request(h.fake)).body
    try Test.assert(body.include?("Answer in one line."), "the prompt: #{body}")
    Test.assert(body.include?("Hi. (asked in a test)"), "the message: #{body}")
  end
end

def test_fold_handlers_add_their_text_after_the_summary() -> Result[Void]
  registry = (
    Core.registry()
    |> Core.on(Core.Event.Fold(->(staying: List[LLM.Message]) { "#{staying.size} kept" }))
    |> Core.on(Core.Event.Fold(->(_staying: List[LLM.Message]) { "" }))
  )

  Test.eq(Extensions.fold(registry, []), "\n\n0 kept")
end

# A service that fails stops those started before it, in the reverse order, and the start fails.
def test_a_failed_service_stops_those_started_before_it() -> Result[Void]
  stopped: Channel[String] = Channel.new(4)
  services = ["a", "b"].map do |name|
    Core.Service(name: name, start: -> { ok() }, stop: -> { _ = stopped.send(name, 0) })
  end

  failing = Core.Service(name: "c", start: -> { error("no port") }, stop: -> { _ = stopped.send("c", 0) })
  started = Core.started(services.push(failing), [])
  try Test.eq(started.ok?, false)
  try Test.eq([stopped.recv(100), stopped.recv(100)], [ok("b"), ok("a")])
  Test.error?(stopped.recv(0))
end
