## A real session on Anthropic's cheap model, which costs money: only `make live-anthropic-core`, with the owner's yes,
## never in CI. It reads `ANTHROPIC_API_KEY`, else `ANTHROPIC_AUTH_TOKEN`, and never prints either.

import LLM from "pkg/llm/llm"
import Protocol from "pkg/protocol/protocol"
import Config from "../src/config"
import Server from "../src/server"
import Tools from "../src/tools"
import Fake from "../tests/support/fake_llm"
import H from "../tests/support/harness"

# Three calls: a turn with one tool round (the call, then the answer), then a second turn, which reads the system
# prompt, the tools and the first turn from the cache.
def test_a_session_on_anthropic_reads_its_cache() -> Result[Void]
  key = System.env("ANTHROPIC_API_KEY").unwrap_or("")
  token = System.env("ANTHROPIC_AUTH_TOKEN").unwrap_or("")
  return error("set ANTHROPIC_API_KEY or ANTHROPIC_AUTH_TOKEN") if key.empty? and token.empty?

  base = "#{System.env("TMPDIR").unwrap_or("/tmp")}/finn-live-#{Random.int(0, 999_999_999)}"
  try Dir.mkdir_private(base)
  base = try Path.real(base)
  result = session(
    base,
    Config.AnthropicAccess(url: LLM.ANTHROPIC_URL, api_key: key, auth_token: token, inherit: false),
  )

  _ = Path.remove(base)
  result
end

def session(base: String, access: Config.AnthropicAccess) -> Result[Void]
  work = "#{base}/work"
  try Dir.mkdir(work)
  try File.write_text("#{work}/README.md", "# Demo\n\nThe secret word is pelican.\n")
  apis = Config.apis("", "", LLM.Options(), access)
  small = {"max_tokens": JSON.from(256), "output_config": JSON.object({"effort": JSON.from("low")})}
  claude = apis["anthropic"].with(extra: small)
  options = Server.Options(
    state_dir: "#{base}/state",
    data_dir: "#{base}/data",
    apis: {"anthropic": claude},
    api: "anthropic",
    model: LLM.ANTHROPIC_CHEAP_MODEL,
    env: ->(_name: String) { error("not set") },
    rules: Tools.Rules(allow: [], deny: []),
    context_window: some(1_000_000),
  )

  fake = try Fake.start([])
  server = try Server.start(options)
  h = H.Harness(
    server: server,
    fake: fake,
    base: base,
    work: work,
    state_dir: options.state_dir,
    data_dir: options.data_dir,
    url: "http://127.0.0.1:#{server.port}",
    token: server.token,
    apis: options.apis,
  )

  result = turns(h)
  Server.stop(server)
  _ = Fake.stop(fake)
  result
end

def turns(h: H.Harness) -> Result[Void]
  id = try H.new_session(h)
  a = try H.subscribe(h, id)
  _ = try H.send(h, id, "Use read_file to read README.md, then say its secret word in one word.")
  a = try H.until(a, Protocol.EventKind.TurnFinished)
  first = usages(a)
  tools = a.seen.select { |s| Protocol.event_name(s.event) == "tool_started" }.size
  _ = try H.send(h, id, "Say done in one word.")
  a = try H.until(a.with(seen: []), Protocol.EventKind.TurnFinished)
  H.close(a)
  second = usages(a)
  report("core anthropic live: tool calls #{tools}, turn 1 #{first}, turn 2 #{second}\n")
  try Test.eq(tools, 1)
  try Test.eq(second.size, 1)
  Test.assert(second[0].cache_read > 0, "the second turn read nothing from the cache: #{second}")
end

def usages(sub: H.Sub) -> List[Protocol.Usage]
  out: List[Protocol.Usage] = []
  for seen in sub.seen
    case seen.event
      Protocol.Event.Usage(u) -> out = out.push(u)
      _ -> nil
    end
  end

  out
end

# The runner drops the output of a passed test: the line goes to the file of `ANTHROPIC_LIVE_REPORT`, which the
# Makefile prints.
def report(line: String) -> Void
  case System.env("ANTHROPIC_LIVE_REPORT")
    ok(path) if not path.empty? -> _ = File.write_text(path, line)
    _ -> nil
  end
end
