## A client of one MCP server, on stdio or streamable HTTP: an actor that owns the server process or the HTTP session
## and sends one request at a time.
##
## The process starts on the first use, in its own process group, so a stop ends the programs it started too. When it
## exits, answers nothing in time or writes a line that is too long, the request fails with `mcp.unavailable` and the
## process is stopped; the next use starts it again. Over HTTP the session is so ended (a DELETE) and started again,
## and a session that the server ended is started again at once, for the same request.

import Actor from "std/actor"
import Http from "http"
import Rpc from "rpc"

CLIENT_NAME = "finn"
UNAVAILABLE = "mcp.unavailable"
CALL_MARGIN_MS = 5000
## The most pages of `tools/list` read; a cursor seen before ends the list too.
MAX_PAGES = 100

## How to start a server: a `command` on stdio, or a `url` on streamable HTTP.
struct Server
  name: String
  command: String = ""
  args: List[String] = []
  ## Variables added to the environment the server inherits.
  env: Map[String, String] = {}
  ## The file that gets the server's stderr; `""` leaves it on ours.
  log: String = ""
  ## The folder the server starts in; `.` is ours.
  cwd: String = "."
  url: String = ""
  ## Headers sent with each HTTP request; their values never show in an error.
  headers: Map[String, String] = {}
end

struct Options
  ## The longest wait for the start and the `initialize` answer.
  start_ms: Int = 30_000
  ## The longest wait for the answer to one request (all the pages of `tools/list` share it), counted from when the
  ## server is up. The initial start has `start_ms` of its own; reopening an expired HTTP session uses both limits.
  timeout_ms: Int = 60_000
  ## The largest JSON answer or SSE event over HTTP.
  max_message_bytes: Int = 4_194_304
end

struct Client
  server: Server
  options: Options
  actor: Actor.Ref[State, Msg]
end

## Starts the client; the server process starts on the first use.
def start(server: Server, version: String, options: Options = Options()) -> Client
  init = -> { State(server: server, options: options, version: version) }
  actor = Actor.start(Actor.Behaviour(init: init, handle: &handle, terminate: some(&terminate)))
  Client(server: server, options: options, actor: actor)
end

def tools(client: Client) -> Result[List[Rpc.Tool]]
  flat(Actor.call(client.actor.address, wait_ms(client)) do |reply| Msg.Tools(reply) end)
end

def call(client: Client, name: String, arguments: JSON.Value) -> Result[Rpc.Output]
  flat(
    Actor.call(client.actor.address, wait_ms(client)) do |reply|
      Msg.Call(CallJob(name: name, arguments: arguments, reply: reply))
    end,
  )
end

## Stops the client and its server process.
def stop(client: Client) -> Void
  _ = Actor.stop(client.actor, CALL_MARGIN_MS)
end

private

struct State
  server: Server
  options: Options
  version: String
  process: Optional[Process] = none
  link: Optional[Http.Link] = none
  next_id: Int = 1
end

struct CallJob
  name: String
  arguments: JSON.Value
  reply: Channel[Result[Rpc.Output]]
end

enum Msg
  Tools(Channel[Result[List[Rpc.Tool]]])
  Call(CallJob)
end

struct Done[T]
  state: State
  result: Result[T]
  ## The original request deadline when an HTTP session has to be reopened.
  deadline: Optional[Int] = none
end

# Allows one start plus the request budget and a margin.
def wait_ms(client: Client) -> Int = client.options.start_ms + client.options.timeout_ms + CALL_MARGIN_MS

def flat[T](result: Result[Result[T]]) -> Result[T]
  case result
    ok(inner) -> inner
    error(e) -> error("mcp: #{e.message}", kind: "mcp.unavailable", cause: e)
  end
end

def handle(state: State, msg: Msg) -> Actor.Step[State]
  case msg
    Msg.Tools(reply) ->
      done = list_tools(state)
      _ = Actor.reply(reply, done.result)
      Actor.continue(done.state)
    Msg.Call(job) ->
      done = call_tool(state, job.name, job.arguments)
      _ = Actor.reply(job.reply, done.result)
      Actor.continue(done.state)
  end
end

def terminate(state: State) -> Void
  _ = closed(state)
end

def closed(state: State) -> State
  for process in option_list(state.process)
    Process.close(process)
  end

  for link in option_list(state.link)
    Http.close(link)
  end

  state.with(process: none, link: none)
end

def list_tools(state: State) -> Done[List[Rpc.Tool]]
  case started(state)
    error(e) -> Done(state: closed(state), result: error(e))
    ok(ready) -> pages(ready, deadline_after_start(ready))
  end
end

# The pages of `tools/list` inside one deadline, so a slow start does not eat the pages' budget (`started` ran first).
def pages(state: State, deadline: Int) -> Done[List[Rpc.Tool]]
  tools: List[Rpc.Tool] = []
  cursor = ""
  seen: Set[String] = Set.new([])
  current = state
  for _page in 1..MAX_PAGES
    done = request(current, "tools/list", Rpc.list_params(cursor), some(deadline))
    current = done.state
    case done.result
      ok(result) ->
        page = Rpc.page(result)
        tools = tools + page.tools
        seen = seen.add(cursor)
        cursor = page.cursor
        return Done(state: current, result: ok(tools)) if cursor.empty? or seen.include?(cursor)
      error(e) -> return Done(state: current, result: error(e))
    end
  end

  Done(state: current, result: ok(tools))
end

# A `tools/call` sets its deadline after the server is ready.
def call_tool(state: State, name: String, arguments: JSON.Value) -> Done[Rpc.Output]
  done = request(state, "tools/call", Rpc.call_params(name, arguments), none)
  case done.result
    ok(result) -> Done(state: done.state, result: ok(Rpc.output(result)))
    error(e) -> Done(state: done.state, result: error(e))
  end
end

# A request on a started server. A failure that leaves the server in doubt stops it; a session that the server ended
# starts again once; the retried request keeps its original deadline.
def request(state: State, method: String, params: JSON.Value, deadline: Optional[Int]) -> Done[JSON.Value]
  done = attempt(state, method, params, deadline)
  case done.result
    error(e) if e.kind == Http.EXPIRED ->
      again = attempt(done.state, method, params, done.deadline)
      case again.result
        error(e2) if e2.kind == Http.EXPIRED -> Done(state: again.state, result: error(e2.message, kind: UNAVAILABLE))
        _ -> again
      end

    _ -> done
  end
end

# Start failures return before a request is sent and cannot trigger a retry.
def attempt(state: State, method: String, params: JSON.Value, deadline: Optional[Int]) -> Done[JSON.Value]
  case started(state, deadline)
    ok(ready) ->
      id = ready.next_id
      next = ready.with(next_id: id + 1)
      due = deadline.unwrap_or(deadline_after_start(ready))
      result = send(next, id, method, params, due)
      case result
        error(e) if e.kind == UNAVAILABLE -> Done(state: closed(next), result: result)
        error(e) if e.kind == Http.EXPIRED -> Done(state: next.with(link: none), result: result, deadline: some(due))
        _ -> Done(state: next, result: result)
      end

    error(e) -> Done(state: closed(state), result: error(e))
  end
end

# The deadline of a request on a state whose start already ran: `start_ms` covered it, so the request gets its whole
# `timeout_ms` from now.
def deadline_after_start(state: State) -> Int = Time.monotonic_ms() + state.options.timeout_ms

def send(state: State, id: Int, method: String, params: JSON.Value, deadline: Int) -> Result[JSON.Value]
  case state.link
    some(link) -> Http.exchange(link, id, method, params, deadline)
    none -> exchange(state.process.unwrap!, id, method, params, deadline)
  end
end

def started(state: State, request_deadline: Optional[Int] = none) -> Result[State]
  return ok(state) if state.process.some? or state.link.some?
  return connected(state, request_deadline) if not state.server.url.empty?

  server = state.server
  spawned = Process.spawn(
    server.command,
    server.args,
    Process.Options(env: server.env, err: server.log, pgroup: true, chdir: server.cwd),
  )

  process = try unavailable(server, spawned)
  ready = state.with(process: some(process))
  deadline = Time.monotonic_ms() + state.options.start_ms
  params = Rpc.initialize_params(CLIENT_NAME, state.version)
  case exchange(process, ready.next_id, "initialize", params, deadline)
    ok(_) ->
      try unavailable(
        server,
        Process.send(process, Rpc.notification("notifications/initialized"), state.options.start_ms),
      )

      ok(ready.with(next_id: ready.next_id + 1))
    error(e) ->
      Process.close(process)
      error(e)
  end
end

def connected(state: State, request_deadline: Optional[Int]) -> Result[State]
  server = state.server
  start_deadline = Time.monotonic_ms() + state.options.start_ms
  # A reopen has only the time left on the original request. Http.open checks before sending initialize.
  deadline = [start_deadline, request_deadline.unwrap_or(start_deadline)].min.unwrap!
  params = Rpc.initialize_params(CLIENT_NAME, state.version)
  opened = Http.open(server.url, server.headers, state.options.max_message_bytes, state.next_id, params, deadline)
  link = try unavailable(server, opened)
  ok(state.with(link: some(link), next_id: state.next_id + 1))
end

# Sends the request and reads lines up to its answer: a request of the server gets its answer on the way, and a
# notification or a line that is no JSON is skipped.
def exchange(process: Process, id: Int, method: String, params: JSON.Value, deadline: Int) -> Result[JSON.Value]
  try down(Process.send(process, Rpc.request(id, method, params), wait(deadline)), method)
  while true
    left = deadline - Time.monotonic_ms()
    return error("mcp: no answer to #{method} in time", kind: "mcp.unavailable") if left <= 0

    text = try down(Process.read_line(process, left), method)
    case Rpc.parse(text)
      ok(incoming) if Rpc.answers?(incoming, id) -> return Rpc.outcome(incoming)
      ok(incoming) if not incoming.method.empty? and incoming.id.some? ->
        try down(Process.send(process, Rpc.answer(incoming.id.unwrap!, incoming.method), wait(deadline)), method)
      _ -> nil
    end
  end

  error("mcp: not reached", kind: "mcp.unavailable")
end

def wait(deadline: Int) -> Int = [deadline - Time.monotonic_ms(), 1].max.unwrap!

def down[T](result: Result[T], method: String) -> Result[T]
  case result
    ok(value) -> ok(value)
    error(e) -> error("mcp: the server stopped answering (#{method}): #{e.message}", kind: "mcp.unavailable", cause: e)
  end
end

def unavailable[T](server: Server, result: Result[T]) -> Result[T]
  case result
    ok(value) -> ok(value)
    error(e) -> error("mcp: cannot start #{server.name}: #{e.message}", kind: "mcp.unavailable", cause: e)
  end
end

def option_list[T](value: Optional[T]) -> List[T]
  case value
    some(x) -> [x]
    none -> []
  end
end
