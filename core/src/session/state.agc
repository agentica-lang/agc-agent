## What the actor of a session holds and the messages it takes: shared by the actor and the files it calls
## (`stream`, `turn`, `branch`).

import LLM from "pkg/llm/llm"
import Protocol from "pkg/protocol/protocol"
import Agent from "../agent/agent"
import Catalog from "../providers/catalog"
import CodeMode from "../tools/code_mode"
import Compaction from "../agent/compaction"
import Extensions from "../config/registry"
import Profiles from "../config/profiles"
import Store from "store"
import Tools from "../tools/tools"

CALL_MS = 5000

## What a session takes from its provider and model API, by their names; `model` is the provider's default.
struct Endpoint
  name: String
  api: String
  model: String
  provider: LLM.Provider
  extra: Map[String, JSON.Value] = {}
  cache: Bool = false
  headers: Map[String, String] = {}
  refresh: Optional[Fn[Result[LLM.Provider]]] = none
  props_url: String = ""
  api_key: String = ""
  compact_model: String = ""
  catalog_provider: String = ""
end

struct Setup
  id: String
  cwd: String
  model: String
  provider: LLM.Provider
  system: String
  ctx: Tools.Context
  keep_events: Int
  approval_timeout_ms: Int
  file: Store.Ref
  ## The model's window in tokens, 0 to ask the provider.
  window: Int = 0
  ## The model that writes a compaction's summary; the session's model when empty.
  compact_model: String = ""
  props_url: String = ""
  api_key: String = ""
  extra: Map[String, JSON.Value] = {}
  code_mode: Optional[CodeMode.Settings] = none
  ## The output limit of every call (`FINN_MAX_TOKENS`); none takes the model's from the catalog.
  max_tokens: Optional[Int] = none
  catalog: Optional[Catalog.Catalog] = none
  catalog_provider: String = ""
  catalog_wait_ms: Int = 1500
  ## How long a turn waits for the queued messages before it goes on without them.
  take_ms: Int = 5000
  ## The most tool rounds of a turn; it ends with `max_rounds` after that many.
  max_rounds: Int = Agent.MAX_ROUNDS
  ## Ask the provider for its prompt cache.
  cache: Bool = false
  ## HTTP headers of every call; `${session}` in a value is the session's id.
  headers: Map[String, String] = {}
  ## A provider with a fresh token, after a 401.
  refresh: Optional[Fn[Result[LLM.Provider]]] = none
  ## What the core's own extensions (the skills) give the session.
  builtins: List[Extensions.Opened] = []
  ## The thinking level of the calls; none leaves it to the model.
  effort: Optional[String] = none
  ## The provider and model API by name, and the endpoint of a provider (with the API now) for a `PATCH`.
  provider_name: String = ""
  api: String = ""
  endpoint: Optional[Fn[String, String, Result[Endpoint]]] = none
  ## The endpoint that serves a model (its provider, the model) on a provider that gives each model its own API; none
  ## for another provider; an error when the model uses an API Finn does not speak. A turn and a compaction take the
  ## provider, fields and API of it, not of `provider`.
  routed: Optional[Fn[String, String, Result[Optional[Endpoint]]]] = none
  ## The provider of the thinking saved before providers, which names none: the session's first, as `provider/api`.
  origin: String = ""
  ## Why a turn cannot start (the provider is not offered now); empty when it can.
  refused: String = ""
  ## The approval, with what the session's answers and mode allowed so far; none runs every call.
  approver: Optional[Extensions.Approver] = none
  ## What the extensions of the server add: the `message` and `fold` handlers.
  registry: Optional[Extensions.Registry] = none
  ## The observers of the extensions, which get the events of the session.
  observers: List[Extensions.Observer] = []
  ## Whether the session's profile shows a tool to the model; none shows every tool.
  shows: Optional[Fn[String, Bool]] = none
  ## The session's profile as clients see it, and why it does not load (empty when it does): a turn is refused then,
  ## also after a provider switch. `system` is `base_system` with the profile's text.
  profile: Optional[Protocol.Profile] = none
  profile_refused: String = ""
  base_system: String = ""
  prompt: Optional[Store.Prompt] = none
  ## The profiles of the session's folders, read again at each call.
  profiles: Optional[Fn[Profiles.Loaded]] = none
  ## What a reload reads again: the system prompt, the extensions' parts and the approval; none for a session that
  ## cannot reload. `skills` are the names the catalog of `system` lists now.
  reopen: Optional[Fn[Result[Reopened]]] = none
  skills: List[String] = []
end

## What a reload gives a session: its system prompt with the project's `AGENTS.md` and the skills catalog read again,
## the extensions' parts and the approval of the rules now, and the names of the skills.
struct Reopened
  system: String
  prompt: Store.Prompt
  builtins: List[Extensions.Opened]
  approver: Optional[Extensions.Approver]
  skills: List[String]
  warnings: List[String] = []
end

## The skills a reload added to a session and took away; they apply from its next turn.
struct Reloaded
  added: List[String] = []
  removed: List[String] = []
  warnings: List[String] = []
end

enum Msg
  Snapshot(Channel[Protocol.Session])
  Subscribe(Optional[Int], Channel[Channel[Bytes]])
  Send(String, Channel[Result[Protocol.MessageAccepted]])
  Answer(String, Protocol.Decision, Channel[Result[Void]])
  Stop(Optional[String], Channel[Bool])
  Place(Channel[Place])
  Close(Channel[Result[Void]])
  Emit(String, Protocol.Event)
  Ask(String, Agent.Ask, Channel[Protocol.Decision])
  Expire(String)
  Commit(String, List[LLM.Message], List[String], List[Agent.Queued])
  Compacted(String, Compaction.Compaction)
  Window(Int)
  ## The turn's id, how it stopped, and the output limit its last call sent.
  Finished(String, Protocol.StopReason, Optional[Int])
  Take(String, Int, Channel[List[Agent.Queued]])
  Update(Protocol.UpdateSession, Channel[Result[Void]])
  ## Reads the system prompt, the skills and the approval again, for the next turn.
  Reload(Channel[Result[Reloaded]])
  Fold(Channel[Result[Fold]])
  Folded(Optional[Compaction.Compaction], Channel[Result[Void]])
  Stripped(String)
  Renewed(LLM.Provider)
  Tree(Channel[Result[Protocol.SessionTree]])
  Exported(Channel[Result[Protocol.SessionExport]])
  Branch(Int, Channel[Result[Protocol.Branched]])
  Copy(Optional[Int], Copying, Channel[Result[Copied]])
  Shell(Protocol.RunShell, Channel[Result[Protocol.ShellAccepted]])
  ShellDone(String, Tools.Output, Int)
  ## The task of the command ended; after its `ShellDone`, if that came.
  ShellDown(String, TaskDown)
  Load(Channel[Load])
end

## Whether the session works now (a turn or a shell command), and whether all it waits for is an answer to an approval.
## The folder of a session and what its rules hide from a listing of it.
struct Place
  root: String
  hidden: Optional[Fn[String, Bool]] = none
end

struct Load
  running: Bool
  asking: Bool
end

## Where `copy` writes the new session: its header, in the folder `dir`.
struct Copying
  header: Store.Header
  dir: String
end

## A copy of a session: its file, and the user message it went back before ("" when none).
struct Copied
  file: Store.Ref
  text: String
end

## What a compaction that a client asked for needs, taken from the session while no turn runs.
struct Fold
  provider: LLM.Provider
  refresh: Optional[Fn[Result[LLM.Provider]]] = none
  settings: Compaction.Settings
  history: List[LLM.Message]
  span: Optional[Compaction.Compaction]
end

struct Waiting
  request: Protocol.ApprovalRequested
  reply: Channel[Protocol.Decision]
  asked_ms: Int
end

## A message sent while a turn runs, until the turn reads it: the `message_id` its sender got, and its text.
struct Unread
  id: String
  text: String
end

struct Running
  id: String
  task: Task[Void]
  from_event_id: Int
  ## The text of the turn's answers so far, kept as it is committed, so a compaction of the history leaves it whole.
  texts: List[String] = []
  ## The messages queued into the turn so far, which number their ids.
  queued: Int = 0
  ## The size of the display when the turn started: what it shows of the turn after that, the events give again.
  shown: Int = 0
end

## A command a client runs in the session folder.
struct ShellRun
  id: String
  command: String
  context: Bool
  task: Task[Void]
  started_ms: Int
end

struct State
  setup: Setup
  prompt_pending: Bool = false
  counter: Int = 0
  log: List[Store.Logged] = []
  subscribers: List[Channel[Bytes]] = []
  history: List[LLM.Message] = []
  display: List[Protocol.Message] = []
  turn: Optional[Running] = none
  turns: Int = 0
  pending: List[Waiting] = []
  approvals: Int = 0
  ## The approvals answered, so a late answer is told it came late.
  resolved: List[String] = []
  ## Since when no client is attached.
  alone_since: Optional[Int] = none
  ## Why the last write to the file failed; none once one works. The next write starts on a new line, since the failed
  ## one may have left part of its line.
  broken: Optional[String] = none
  ## The output tokens of every call of the session.
  output: Int = 0
  ## The context of the last call, and its `usage` as the clients got it.
  context: Int = 0
  usage: Optional[Protocol.Usage] = none
  ## What the calls cost in USD, from the catalog's prices: the session's and the running turn's.
  cost: Optional[Float] = none
  turn_cost: Float = 0.0
  ## Messages sent while the turn runs, which it has not read yet. They live only here: a crash of the server loses
  ## them with no `queue_dropped`.
  queued: List[Unread] = []
  ## The names the extensions noted: the skills the session loaded.
  marks: List[String] = []
  ## The model's window: 0 until it is known, -1 when the provider does not say.
  window: Int = 0
  ## The ids up to this one are saved or reserved in the file.
  reserved: Int = 0
  ## Loaded from the file: a client that attaches from before this id would miss deltas that were not saved.
  lost_below: Int = 0
  ## The turn that a failed write stopped, for a client that attaches from inside it.
  lost: Optional[Lost] = none
  ## A compaction that a client asked for runs: no turn starts meanwhile.
  compacting: Bool = false
  ## Anthropic requests go without thinking blocks until the next fold: a turn passed the limit inside a tool round.
  stripped: Bool = false
  ## The tree of the file as far as the session read it.
  entries: Optional[Store.Entries] = none
  shell: Optional[ShellRun] = none
  ## The output of the commands that go to the model before the next message.
  shells: List[String] = []
  ## The model's todo list: that of the last `todos` event on the branch.
  todos: List[Protocol.Todo] = []
end

## The end of a turn that a failed write stopped: the clients got `frames` without an id after event `to`, and a
## client whose replay passes `to` gets them again.
struct Lost
  to: Int
  frames: List[String]
end

def busy?(state: State) -> Bool = state.turn.some? or state.compacting or state.shell.some?

def busy_reason(state: State) -> String
  return "a turn is running" if state.turn.some?
  return "a shell command is running" if state.shell.some?

  "the history is being compacted"
end

def choice(setup: Setup) -> Store.Choice
  Store.Choice(
    model: setup.model,
    effort: setup.effort,
    provider: setup.provider_name,
    api: setup.api,
    profile: setup.profile.map { |p| p.name },
  )
end

def last_todos(events: List[Store.Logged]) -> List[Protocol.Todo]
  last: List[Protocol.Todo] = []
  for logged in events
    case logged.event
      Protocol.Event.Todos(list) -> last = list.todos
      _ -> nil
    end
  end

  last
end

def last_usage(events: List[Store.Logged]) -> Protocol.Usage
  last = Protocol.Usage(input: 0, output: 0, cache_read: 0, cache_write: 0, context: 0)
  for logged in events
    case logged.event
      Protocol.Event.Usage(usage) -> last = usage
      _ -> nil
    end
  end

  last
end
