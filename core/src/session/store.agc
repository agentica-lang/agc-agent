## The file of a session in the data folder: JSON Lines, appended as the session goes. The first line is the session;
## then one line per event but the deltas (with its id), per block of ids the deltas take, per user message, per
## round of the model's history and per answer a client draws. A record is one line, written whole or cut by a crash:
## loading skips a line that does not parse or decode, and `reopen` ends a line that a crash left open.
##
## The records form a tree. The number of its line is a record's entry, and each record follows the one before it,
## except after a `branch` record: the records after it follow the entry it names. A load replays the branch that ends
## at the last record. The event ids, the settings and the cost are the whole file's.
##
## The file keeps the events and messages in plain text, tool output and file contents included, until it is removed.
## The files are kept by a `Storage.Port`: `disk` in the data folder, `memory` for tests.

import LLM from "pkg/llm/llm"
import Protocol from "pkg/protocol/protocol"
import Compaction from "../agent/compaction"
import Storage from "storage"

export Storage.Port

EXTENSION = ".jsonl"
## Beside a session file: the model of its last `settings` record, so a list of the sessions need not read the file.
SETTINGS_EXTENSION = ".settings.json"
## A listing looks this far into a file for the first user message: the lines, and the bytes.
TITLE_LINES = 64
TITLE_BYTES = 262_144
MAX_LINE_BYTES = 16_777_216
MAX_WRITE_BYTES = 1_048_576
## A node of the tree has this much of its answer.
ANSWER_CHARS = 200

struct Header
  id: String
  cwd: String
  model: String
  created_ms: Int
  ## The system prompt of every call of the session, so a cache of its prefix stays valid after a restart.
  system: Optional[String] = none
  ## The model API of the session, by its `FINN_API` name; none in a file made before the choice.
  api: Optional[String] = none
  ## The provider of the session; none in a file made before providers.
  provider: Optional[String] = none
  ## The profile of the session; none is `build`.
  profile: Optional[String] = none
end

struct Logged
  id: Int
  event: Protocol.Event
end

## What a file holds. `open_end` is true when its last line has no end (a crash cut it): `reopen` before an append.
## `users` counts the turns that began, and `open_user` is true when the last one has no `turn_started`.
struct Saved
  header: Header
  events: List[Logged]
  history: List[LLM.Message]
  shown: List[Protocol.Message]
  skipped: Int
  open_end: Bool
  users: Int = 0
  open_user: Bool = false
  ## After the last saved event, the ids up to this one may have gone to events that are not saved; 0 when none.
  reserved: Int = 0
  ## The answer of the last turn so far at its last compaction, which may have folded part of it.
  folded: Optional[Folded] = none
  ## A `stripped` record and no compaction after it.
  stripped: Bool = false
  ## The names that extensions noted in the session (the skills it loaded), in order.
  marks: List[String] = []
  ## The model, the thinking level, the provider and the model API of the last `settings` record: what the session
  ## changed since its header (an older record has no provider and API).
  model: Optional[String] = none
  effort: Optional[String] = none
  provider: Optional[String] = none
  api: Optional[String] = none
  ## The profile of the last `settings` record that names one.
  profile: Optional[String] = none
  ## The last event id of the whole file, the number of its approval requests and of its turns, and its last `usage`.
  last_id: Int = 0
  approvals: Int = 0
  turns: Int = 0
  usage: Optional[Protocol.Usage] = none
  ## The output of the commands since the last user message that go to the model before the next one.
  shells: List[String] = []
end

## Where a branch or a copy starts: the entry the next record follows, and the user message it goes back before ("" at
## the end of a turn).
struct Point
  leaf: Int
  text: String = ""
end

## What a `settings` record changes.
struct Choice
  model: String
  effort: Optional[String]
  provider: String
  api: String
  profile: Optional[String] = none
end

## A record of the file: its line number is its entry, `parent` the entry it follows (the session's line for the
## first). `text` is what the tree shows of it; `json` and `line` are kept only for a load or a copy.
struct Record
  at: Int
  kind: String
  parent: Int
  text: String = ""
  json: Optional[JSON.Value] = none
  line: String = ""
end

## The lines of a file as a tree. `start` is the line of the session, `records` every record but the branches by its
## entry, `order` their entries in the file, `branches` the entry each branch line names, and `leaf` the entry the
## next record follows. `lines` and `size` are how much of the file it read.
struct Entries
  header: Header
  start: Int
  records: Map[Int, Record] = {}
  order: List[Int] = []
  branches: Map[Int, Int] = {}
  leaf: Int
  skipped: Int = 0
  lines: Int = 0
  size: Int = 0
end

## What a list of the sessions shows of one file: the model, provider and API of its last `settings` record, and its
## first user message.
struct Listing
  model: Optional[String] = none
  provider: Optional[String] = none
  api: Optional[String] = none
  title: String = ""
end

## The answer texts of a turn when it was compacted, and the size of the history after: the texts of the messages
## from there on follow them.
struct Folded
  texts: List[String]
  at: Int
end

## A session file: its path in the port that keeps it.
struct Ref
  port: Storage.Port
  path: String
end

def disk() -> Storage.Port = Storage.disk(MAX_LINE_BYTES, MAX_WRITE_BYTES)

def memory(folders: List[String]) -> Storage.Port = Storage.memory(MAX_LINE_BYTES, folders)

def file_of(dir: String, id: String) -> String = "#{dir}/#{id}#{EXTENSION}"

## The session files of `dir`, by their extension.
def all(port: Storage.Port, dir: String) -> Result[List[Ref]]
  names = (try port.names.call(dir)).select { |name| name.end_with?(EXTENSION) }
  ok(names.map { |name| Ref(port: port, path: "#{dir}/#{name}") })
end

## Creates the file of a new session (0600).
def create(port: Storage.Port, dir: String, header: Header) -> Result[Ref]
  file = Ref(port: port, path: file_of(dir, header.id))
  fields = {
    "type": JSON.from("session"),
    "id": JSON.from(header.id),
    "cwd": JSON.from(header.cwd),
    "model": JSON.from(header.model),
    "created_ms": JSON.from(header.created_ms),
    "system": JSON.from(header.system),
    "api": JSON.from(header.api),
    "provider": JSON.from(header.provider),
    "profile": JSON.from(header.profile),
  }

  try port.create.call(file.path, try line(fields))
  ok(file)
end

## Removes a session file and the file beside it.
def remove(file: Ref) -> Result[Void]
  try file.port.remove.call(file.path)
  _ = file.port.remove.call(settings_file(file.path))
  ok()
end

## The size of the file and its time of change.
def changed(file: Ref) -> Result[Storage.Stat] = file.port.stat.call(file.path)

def append_event(file: Ref, logged: Logged) -> Result[Void]
  data = try JSON.parse(Protocol.encode_event(logged.event))
  name = Protocol.event_name(logged.event)
  append(file, {"type": JSON.from("event"), "id": JSON.from(logged.id), "name": JSON.from(name), "data": data})
end

## The message that starts a turn, the first of the turn's history; `typed` is what is shown when not empty (the text
## without what extensions put before it) and `marks` the names they noted. With `shells`, the model's message starts
## with the output of the commands since the last user message, which their `shell_finished` events hold.
def append_user(
  file: Ref,
  text: String,
  typed: String = "",
  marks: List[String] = [],
  shells: Bool = false,
) -> Result[Void]
  fields = {"type": JSON.from("user"), "text": JSON.from(text)}
  if typed != "" and typed != text
    fields = fields.put("typed", JSON.from(typed))
  end

  if shells
    fields = fields.put("shells", JSON.from(true))
  end

  append(file, with_marks(fields, marks))
end

## A message sent during a turn, once the turn read it: shown as a user message that starts no turn. The history has it
## in the `messages` record that follows.
def append_queued(file: Ref, text: String) -> Result[Void]
  append(file, {"type": JSON.from("queued"), "text": JSON.from(text)})
end

## The messages a round added to the history, in one record so that a call never goes without its result, with the
## names extensions noted in the round.
def append_messages(file: Ref, messages: List[LLM.Message], marks: List[String] = []) -> Result[Void]
  fields = {"type": JSON.from("messages"), "messages": JSON.array(messages.map { |m| encode_message(m) })}
  append(file, with_marks(fields, marks))
end

## Ids up to `until` may go to events that are not saved (deltas), so a restart starts after them. A saved event
## after it ends the reservation.
def append_reserved(file: Ref, until: Int) -> Result[Void]
  append(file, {"type": JSON.from("ids"), "until": JSON.from(until)})
end

## A compaction of the history as the records before it left it, with the answer texts of the running turn so far.
def append_compaction(file: Ref, compaction: Compaction.Compaction, answer: List[String]) -> Result[Void]
  append(
    file,
    {
      "type": JSON.from("compaction"),
      "from": JSON.from(compaction.from),
      "to": JSON.from(compaction.to),
      "summary": JSON.from(compaction.summary),
      "answer": JSON.from(answer),
      "strip_thinking": JSON.from(compaction.strip_thinking),
    },
  )
end

## From now until the next compaction the session's Anthropic requests go without thinking blocks.
def append_stripped(file: Ref) -> Result[Void] = append(file, {"type": JSON.from("stripped")})

## The model and thinking level the session uses from now on, also in the file beside it (0600, replaced whole). The
## record goes first: the session restores from it, and the side file only feeds the list of the sessions, so a side
## file that cannot be written leaves the list with the model before while the change holds.
def append_settings(file: Ref, settings: Choice) -> Result[Void]
  chosen = {
    "model": JSON.from(settings.model),
    "provider": JSON.from(settings.provider),
    "api": JSON.from(settings.api),
  }

  fields = chosen.put("type", JSON.from("settings")).put("effort", JSON.from(settings.effort))
  try append(file, fields.put("profile", JSON.from(settings.profile)))
  _ = file.port.replace.call(settings_file(file.path), JSON.encode(JSON.object(chosen)))
  ok()
end

## The answer of a turn, as a client draws it.
def append_answer(file: Ref, text: String) -> Result[Void]
  append(file, {"type": JSON.from("answer"), "text": JSON.from(text)})
end

def reopen(file: Ref) -> Result[Void] = write(file, "\n")

## From now on the records follow entry `leaf`, a `Point` of the file. The branch takes event id `until`, so a client
## that saw an id before it gets `resync`, after a restart too.
def append_branch(file: Ref, leaf: Int, until: Int) -> Result[Void]
  branch = try line({"type": JSON.from("branch"), "parent": JSON.from(leaf)})
  write(file, branch + try line({"type": JSON.from("ids"), "until": JSON.from(until)}))
end

## The tree of the file, reading only the lines after those `known` read when the file grew since: the session's
## file only grows, and only its session writes it. A last line with no newline yet is left for a later read.
def entries(file: Ref, known: Optional[Entries] = none) -> Result[Entries]
  for old in option_list(known)
    size = (try changed(file)).size
    return ok(old) if old.size == size
  end

  read = try file.port.read.call(file.path)
  for old in option_list(known)
    if old.size < read.size
      added = ended(read.lines.drop(old.lines), read.size - old.size)
      return ok(extended(old, added, false).with(size: old.size + bytes_of(added)))
    end
  end

  lines = ended(read.lines, read.size)
  ok((try entries_of(file.path, lines, false)).with(size: bytes_of(lines)))
end

## The user messages of every branch.
def tree(entries: Entries) -> Protocol.SessionTree = Protocol.SessionTree(nodes: turns(entries))

## Where a branch from `entry` starts: before it when it is a user message, at it when it ends a turn (`last` of the
## tree) or is the session's first line; the end of the current branch when none.
def point(entries: Entries, entry: Optional[Int]) -> Result[Point]
  return ok(Point(leaf: entries.leaf)) if entry.none?

  at = entry.unwrap!
  return ok(Point(leaf: at)) if at == entries.start

  for turn in turns(entries)
    return ok(Point(leaf: entries.records[at].parent, text: turn.text)) if turn.id == at
    return ok(Point(leaf: at)) if turn.last == at
  end

  error("no turn starts or ends at entry #{at}", kind: Protocol.KIND_INVALID)
end

## A new session file of `header` (0600) with the records of the branch that ends at `leaf`. A copy that
## fails is removed.
def copy(file: Ref, dir: String, header: Header, leaf: Int) -> Result[Ref]
  entries = try read_entries(file)
  return error("no entry #{leaf}", kind: Protocol.KIND_INVALID) if not entry?(entries, leaf)

  created = try create(file.port, dir, header)
  written = write(created, branch(entries, leaf).map { |record| "#{record.line}\n" }.join(""))
  if not written.ok?
    _ = created.port.remove.call(created.path)
  end

  try written
  ok(created)
end

## The model from the file beside the session's, and the first user message from the first TITLE_LINES lines in the
## first TITLE_BYTES bytes (none when its line does not end in them).
def listing(file: Ref) -> Result[Listing]
  title = first_user(decoded(try file.port.head.call(file.path, TITLE_BYTES)))
  side = side_settings(file)
  ok(
    Listing(
      model: side_field(side, "model"),
      provider: side_field(side, "provider"),
      api: side_field(side, "api"),
      title: title,
    ),
  )
end

## The first line of a file: the session, without reading the rest.
def header(file: Ref) -> Result[Header] = decode_header(try JSON.parse(try file.port.first_line.call(file.path)))

## The branch that ends at `leaf`, a `Point` of the file; the current one when none.
def load(file: Ref, leaf: Optional[Int] = none) -> Result[Saved]
  read = try file.port.read.call(file.path)
  entries = try entries_of(file.path, read.lines, true)
  end_at = leaf.unwrap_or(entries.leaf)
  return error("no entry #{end_at}", kind: Protocol.KIND_INVALID) if not entry?(entries, end_at)

  saved = Saved(
    header: entries.header,
    events: [],
    history: [],
    shown: [],
    skipped: entries.skipped,
    open_end: read.size != bytes_of(read.lines),
  )

  for record in branch(entries, end_at)
    case added(saved, json_of(record))
      ok(next_saved) -> saved = next_saved
      error(_) -> saved = saved.with(skipped: saved.skipped + 1)
    end
  end

  ok(totals(saved, entries))
end

## The records of the branch the file is on now, in order, as JSON.
def branch_records(file: Ref) -> Result[List[JSON.Value]]
  entries = try read_entries(file)
  ok(branch(entries, entries.leaf).map { |record| json_of(record) })
end

## The text of a user message after the output of the commands before it.
def with_shells(shells: List[String], text: String) -> String = (shells + [text]).join("\n\n")

## A command's output as the model gets it, before the next user message.
def shell_context(finished: Protocol.ShellFinished) -> String
  output = finished.output
  if output.strip.empty?
    output = "(no output)"
  end

  "The user ran `#{finished.command}` in the session folder:\n```\n#{output}\n```"
end

def encode_message(message: LLM.Message) -> JSON.Value
  role = case message.role
    LLM.Role.User -> "user"
    LLM.Role.Assistant -> "assistant"
  end

  JSON.object({"role": JSON.from(role), "content": JSON.array(message.content.map { |b| encode_block(b) })})
end

def decode_message(json: JSON.Value) -> Result[LLM.Message]
  role = try role_of(try field(json, "role"))

  content: List[LLM.Block] = []
  for item in try JSON.list(try JSON.get(json, "content"))
    content = content.push(try decode_block(item))
  end

  ok(LLM.Message(role: role, content: content))
end

private

struct Settings
  model: Optional[String] = none
  effort: Optional[String] = none
  provider: Optional[String] = none
  api: Optional[String] = none
  profile: Optional[String] = none
end

# Every record of the file with its JSON and its line, for a load or a copy.
def read_entries(file: Ref) -> Result[Entries]
  entries_of(file.path, (try file.port.read.call(file.path)).lines, true)
end

# A line that does not parse, has no `type` or is a branch to an entry that is not before it is skipped. Without
# `whole`, a record keeps only its `text`.
def entries_of(path: String, lines: List[String], whole: Bool) -> Result[Entries]
  skipped = 0
  for at in 0...lines.size
    next if lines[at].empty?

    case JSON.parse(lines[at])
      ok(json) ->
        header = try decode_header(json)
        started = Entries(header: header, start: at, leaf: at, skipped: skipped, lines: at + 1)
        return ok(extended(started, lines.drop(at + 1), whole))
      error(_) -> skipped = skipped + 1
    end
  end

  error("#{path}: no session record")
end

# The entries with the lines that follow the ones they read.
def extended(entries: Entries, lines: List[String], whole: Bool) -> Entries
  records = entries.records
  order = entries.order
  branches = entries.branches
  leaf = entries.leaf
  skipped = entries.skipped
  for i in 0...lines.size
    at = entries.lines + i
    text = lines[i]
    next if text.empty?

    case JSON.parse(text)
      ok(json) ->
        kind = field(json, "type").unwrap_or("")
        target = branch_target(json, at, entries.start, records, branches)
        if kind == "branch" and target.some?
          leaf = target.unwrap!
          branches = branches.put(at, leaf)
        elsif kind != "" and kind != "branch"
          record = Record(at: at, kind: kind, parent: leaf, text: record_text(kind, json))
          if whole
            record = record.with(json: some(json), line: text)
          end

          records = records.put(at, record)
          order = order.push(at)
          leaf = at
        else
          skipped = skipped + 1
        end

      error(_) -> skipped = skipped + 1
    end
  end

  entries.with(
    records: records,
    order: order,
    branches: branches,
    leaf: leaf,
    skipped: skipped,
    lines: entries.lines + lines.size,
  )
end

# The lines that end in a newline, of lines that take `bytes` with their newlines.
def ended(lines: List[String], bytes: Int) -> List[String]
  return lines if bytes_of(lines) == bytes

  lines.take(lines.size - 1)
end

def clipped(text: String) -> String = text.slice(0, [text.length, ANSWER_CHARS].min.unwrap!)

def bytes_of(lines: List[String]) -> Int = lines.map { |text| text.bytesize + 1 }.sum

# What the tree keeps of a record: the text of a user message (a branch puts it back in the editor), the first line
# of an answer cut to ANSWER_CHARS, the name of an event.
def record_text(kind: String, json: JSON.Value) -> String
  case kind
    "user" -> optional_string(json, "typed").unwrap_or(field(json, "text").unwrap_or(""))
    "answer" -> clipped(field(json, "text").unwrap_or("").split("\n")[0])
    "event" -> field(json, "name").unwrap_or("")
    _ -> ""
  end
end

# The entry a branch record names, before it; a branch to a branch is to the entry that one names.
def branch_target(
  json: JSON.Value,
  at: Int,
  start: Int,
  records: Map[Int, Record],
  branches: Map[Int, Int],
) -> Optional[Int]
  parent = JSON.int(JSON.get(json, "parent").unwrap_or(JSON.null())).unwrap_or(-1)
  return none if parent >= at
  return some(parent) if parent == start or records.has_key?(parent)

  branches.get(parent)
end

def entry?(entries: Entries, at: Int) -> Bool = at == entries.start or entries.records.has_key?(at)

def json_of(record: Record) -> JSON.Value = record.json.unwrap_or(JSON.null())

# The records from the session's line to `leaf`, in order.
def branch(entries: Entries, leaf: Int) -> List[Record]
  out: List[Record] = []
  at = leaf
  while at != entries.start
    record = entries.records[at]
    out = out.push(record)
    at = record.parent
  end

  out.reverse
end

# The event ids, the settings and the cost of every branch: ids and approval ids are never given twice, and the model,
# the effort and the cost are the session's whatever branch it is on.
def totals(saved: Saved, entries: Entries) -> Saved
  last_id = 0
  reserved = 0
  approvals = 0
  users = 0
  started = 0
  usage: Optional[JSON.Value] = none
  settings = Settings()
  for at in entries.order
    record = entries.records[at]
    case record.kind
      "event" ->
        name = field(json_of(record), "name").unwrap_or("")
        if Protocol.parse_kind(name).ok?
          last_id = [
            last_id,
            JSON.int(JSON.get(json_of(record), "id").unwrap_or(JSON.null())).unwrap_or(0),
          ].max.unwrap!

          reserved = 0
        end

        if name == "approval_requested"
          approvals = approvals + 1
        end

        if name == "turn_started"
          started = started + 1
        end

        if name == "usage"
          usage = some(json_of(record))
        end

      "user" -> users = users + 1
      "ids" -> reserved = JSON.int(JSON.get(json_of(record), "until").unwrap_or(JSON.null())).unwrap_or(reserved)
      "settings" -> settings = settings_of(json_of(record)).unwrap_or(settings)
      _ -> nil
    end
  end

  saved.with(
    last_id: last_id,
    reserved: reserved,
    approvals: approvals,
    turns: [users, started].max.unwrap!,
    usage: usage_of(usage),
    model: settings.model,
    effort: settings.effort,
    provider: settings.provider,
    api: settings.api,
    profile: settings.profile,
  )
end

def usage_of(json: Optional[JSON.Value]) -> Optional[Protocol.Usage]
  for record in option_list(json)
    data = JSON.encode(JSON.get(record, "data").unwrap_or(JSON.null()))
    case Protocol.decode_event("usage", data)
      ok(Protocol.Event.Usage(usage)) -> return some(usage)
      _ -> nil
    end
  end

  none
end

# The user messages as the nodes of a tree: the message before each on its branch, and the entry that ends its turn
# (its `turn_finished`, so records that follow it later do not move it).
def turns(entries: Entries) -> List[Protocol.TreeNode]
  children: Map[Int, List[Int]] = {}
  for at in entries.order
    parent = entries.records[at].parent
    children = children.put(parent, children.get(parent, []).push(at))
  end

  active = Set.new(branch(entries, entries.leaf).map { |record| record.at })
  users = entries.order.select { |at| entries.records[at].kind == "user" }
  users.map { |at| node(entries, children, active, at) }
end

def node(entries: Entries, children: Map[Int, List[Int]], active: Set[Int], at: Int) -> Protocol.TreeNode
  record = entries.records[at]
  last = at
  answer = ""
  while true
    following = children.get(last, []).select { |child| entries.records[child].kind != "user" }
    break if following.size != 1

    last = following[0]
    if entries.records[last].kind == "answer"
      answer = entries.records[last].text
    end

    break if entries.records[last].kind == "event" and entries.records[last].text == "turn_finished"
  end

  Protocol.TreeNode(
    id: at,
    parent: user_before(entries, record.parent),
    text: record.text,
    answer: answer,
    last: last,
    active: active.include?(at),
  )
end

def user_before(entries: Entries, from: Int) -> Optional[Int]
  at = from
  while at != entries.start
    record = entries.records[at]
    return some(at) if record.kind == "user"

    at = record.parent
  end

  none
end

# The text of bytes that may end inside a character; a byte that is not UTF-8 becomes U+FFFD, line by line, so one bad
# byte spoils only its character.
def decoded(bytes: Bytes) -> String
  # The read may cut the last character (at most 3 of its bytes).
  for cut in 0..3
    case String.from_bytes(bytes.take([bytes.size - cut, 0].max.unwrap!))
      ok(text) -> return text
      error(_) -> nil
    end
  end

  # latin-1 maps each byte to one character and back, so it finds the lines without decoding them.
  lines = bytes.decode("latin-1").unwrap_or("").split("\n")
  lines.map { |line| utf8_line(line.encode("latin-1").unwrap_or("".bytes)) }.join("\n")
end

def utf8_line(bytes: Bytes) -> String
  case String.from_bytes(bytes)
    ok(text) -> text
    error(_) -> replaced(bytes)
  end
end

# Each complete UTF-8 sequence as its character, anything else as U+FFFD for one byte.
def replaced(bytes: Bytes) -> String
  out: List[String] = []
  at = 0
  while at < bytes.size
    size = sequence_size(bytes[at])
    case String.from_bytes(bytes.slice(at, [size, bytes.size - at].min.unwrap!))
      ok(text) if size > 0 ->
        out = out.push(text)
        at = at + size
      _ ->
        out = out.push(String.from_code(0xfffd))
        at = at + 1
    end
  end

  out.join("")
end

def sequence_size(lead: Int) -> Int
  return 1 if lead < 0x80
  return 2 if lead >= 0xc2 and lead < 0xe0
  return 3 if lead >= 0xe0 and lead < 0xf0
  return 4 if lead >= 0xf0 and lead < 0xf5

  0
end

def first_user(start: String) -> String
  for text in start.split("\n").take(TITLE_LINES)
    next if not text.include?("\"user\"")

    case JSON.parse(text)
      ok(json) if field(json, "type") == ok("user") -> return field(json, "text").unwrap_or("")
      _ -> nil
    end
  end

  ""
end

# A line longer than a load reads is refused.
def line(fields: Map[String, JSON.Value]) -> Result[String]
  text = "#{JSON.encode(JSON.object(fields))}\n"
  return error("a record of #{text.bytesize} bytes is over #{MAX_LINE_BYTES}") if text.bytesize > MAX_LINE_BYTES

  ok(text)
end

def append(file: Ref, fields: Map[String, JSON.Value]) -> Result[Void] = write(file, try line(fields))

def write(file: Ref, text: String) -> Result[Void] = file.port.append.call(file.path, text)

def field(json: JSON.Value, key: String) -> Result[String] = JSON.string(try JSON.get(json, key))

def decode_header(json: JSON.Value) -> Result[Header]
  return error("the first record is not the session") if try field(json, "type") != "session"

  ok(
    Header(
      id: try field(json, "id"),
      cwd: try field(json, "cwd"),
      model: try field(json, "model"),
      created_ms: try JSON.int(try JSON.get(json, "created_ms")),
      system: optional_string(json, "system"),
      api: optional_string(json, "api"),
      provider: optional_string(json, "provider"),
      profile: optional_string(json, "profile"),
    ),
  )
end

def added(saved: Saved, json: JSON.Value) -> Result[Saved]
  kind = try field(json, "type")
  case kind
    "event" ->
      event = try Protocol.decode_event(try field(json, "name"), JSON.encode(try JSON.get(json, "data")))
      logged = Logged(id: try JSON.int(try JSON.get(json, "id")), event: event)
      started = Protocol.event_kind(event) == Protocol.EventKind.TurnStarted
      shells = saved.shells
      case event
        Protocol.Event.ShellFinished(finished) if finished.context -> shells = shells.push(shell_context(finished))
        _ -> nil
      end

      events = saved.events.push(logged)
      ok(saved.with(events: events, open_user: saved.open_user and not started, reserved: 0, shells: shells))
    "user" ->
      text = try field(json, "text")
      shown = Protocol.Message(role: Protocol.Role.User, text: optional_string(json, "typed").unwrap_or(text))
      if JSON.bool(JSON.get(json, "shells").unwrap_or(JSON.from(false))).unwrap_or(false)
        text = with_shells(saved.shells, text)
      end

      message = LLM.Message(role: LLM.Role.User, content: [LLM.Block.Text(LLM.TextPart(text: text))])
      users = saved.users + 1
      ok(
        saved.with(
          history: saved.history.push(message),
          shown: saved.shown.push(shown),
          users: users,
          open_user: true,
          folded: none,
          marks: saved.marks + marks_of(json),
          shells: [],
        ),
      )
    "queued" ->
      shown = Protocol.Message(role: Protocol.Role.User, text: try field(json, "text"))
      ok(saved.with(shown: saved.shown.push(shown)))
    "messages" ->
      messages: List[LLM.Message] = []
      for item in try JSON.list(try JSON.get(json, "messages"))
        messages = messages.push(try decode_message(item))
      end

      ok(saved.with(history: saved.history + messages, marks: saved.marks + marks_of(json)))
    "compaction" ->
      compaction = Compaction.Compaction(
        from: try JSON.int(try JSON.get(json, "from")),
        to: try JSON.int(try JSON.get(json, "to")),
        summary: try field(json, "summary"),
        strip_thinking: JSON.bool(JSON.get(json, "strip_thinking").unwrap_or(JSON.from(false))).unwrap_or(false),
      )

      return error("a compaction outside the history") if compaction.to > saved.history.size

      history = Compaction.apply(saved.history, compaction)
      folded = saved.folded
      # An `answer` that is missing or not a list of texts leaves the answer as it was.
      for texts in answer_texts(json)
        folded = some(Folded(texts: texts, at: history.size))
      end

      ok(saved.with(history: history, folded: folded, stripped: false))
    "stripped" -> ok(saved.with(stripped: true))
    "ids" -> ok(saved.with(reserved: try JSON.int(try JSON.get(json, "until"))))
    "settings" ->
      settings = try settings_of(json)
      ok(saved.with(model: settings.model, effort: settings.effort, provider: settings.provider, api: settings.api))
    "answer" ->
      shown = Protocol.Message(role: Protocol.Role.Assistant, text: try field(json, "text"))
      ok(saved.with(shown: saved.shown.push(shown)))
    _ -> error("unknown record #{kind}")
  end
end

def settings_of(json: JSON.Value) -> Result[Settings]
  effort = optional_string(json, "effort")
  for level in option_list(effort)
    return error("unknown effort #{level}") if not Protocol.EFFORTS.include?(level)
  end

  ok(
    Settings(
      model: some(try field(json, "model")),
      effort: effort,
      provider: optional_string(json, "provider"),
      api: optional_string(json, "api"),
      profile: optional_string(json, "profile"),
    ),
  )
end

def with_marks(fields: Map[String, JSON.Value], marks: List[String]) -> Map[String, JSON.Value]
  return fields if marks.empty?

  fields.put("marks", JSON.from(marks))
end

# A `marks` that is missing or not a list of texts is none.
def marks_of(json: JSON.Value) -> List[String]
  case JSON.get(json, "marks")
    ok(value) -> JSON.decode(value, List[String]).unwrap_or([])
    error(_) -> []
  end
end

def answer_texts(json: JSON.Value) -> List[List[String]]
  case JSON.get(json, "answer")
    ok(value) ->
      case JSON.decode(value, List[String])
        ok(texts) -> [texts]
        error(_) -> []
      end

    error(_) -> []
  end
end

def encode_block(block: LLM.Block) -> JSON.Value
  case block
    LLM.Block.Text(part) -> with_replay({"type": JSON.from("text"), "text": JSON.from(part.text)}, part.replay)
    LLM.Block.Thinking(part) ->
      fields = {"type": JSON.from("thinking"), "text": JSON.from(part.text)}
      if not part.source.empty?
        fields = fields.put("source", JSON.from(part.source))
      end

      with_replay(fields, part.replay)
    LLM.Block.ToolUse(call) ->
      kind = case call.kind
        LLM.ToolKind.Function -> "function"
        LLM.ToolKind.Custom -> "custom"
      end

      fields = {
        "type": JSON.from("tool_use"),
        "id": JSON.from(call.id),
        "name": JSON.from(call.name),
        "arguments": JSON.from(call.arguments),
        "input": call.input,
        "kind": JSON.from(kind),
      }

      for problem in option_list(call.input_error)
        fields = fields.put("input_error", JSON.from(problem))
      end

      with_replay(fields, call.replay)
    LLM.Block.ToolResult(output) ->
      JSON.object({
        "type": JSON.from("tool_result"),
        "tool_use_id": JSON.from(output.tool_use_id),
        "content": JSON.from(output.content),
        "is_error": JSON.from(output.is_error),
      })
  end
end

def with_replay(fields: Map[String, JSON.Value], replay: Optional[JSON.Value]) -> JSON.Value
  case replay
    some(value) -> JSON.object(fields.put("replay", value))
    none -> JSON.object(fields)
  end
end

def decode_block(json: JSON.Value) -> Result[LLM.Block]
  replay = optional(json, "replay")
  kind = try field(json, "type")
  case kind
    "text" -> ok(LLM.Block.Text(LLM.TextPart(text: try field(json, "text"), replay: replay)))
    "thinking" ->
      source = optional_string(json, "source").unwrap_or("")
      ok(LLM.Block.Thinking(LLM.ThinkingPart(text: try field(json, "text"), replay: replay, source: source)))
    "tool_use" ->
      call = LLM.ToolCall(
        id: try field(json, "id"),
        name: try field(json, "name"),
        arguments: try field(json, "arguments"),
        input: try JSON.get(json, "input"),
        input_error: optional(json, "input_error").map { |v| JSON.string(v).unwrap_or("") },
        kind: try tool_kind_of(try field(json, "kind")),
        replay: replay,
      )

      ok(LLM.Block.ToolUse(call))
    "tool_result" ->
      output = LLM.ToolOutput(
        tool_use_id: try field(json, "tool_use_id"),
        content: try field(json, "content"),
        is_error: try JSON.bool(try JSON.get(json, "is_error")),
      )

      ok(LLM.Block.ToolResult(output))
    _ -> error("unknown block #{kind}")
  end
end

def role_of(name: String) -> Result[LLM.Role]
  case name
    "user" -> ok(LLM.Role.User)
    "assistant" -> ok(LLM.Role.Assistant)
    _ -> error("unknown role #{name}")
  end
end

def tool_kind_of(name: String) -> Result[LLM.ToolKind]
  case name
    "function" -> ok(LLM.ToolKind.Function)
    "custom" -> ok(LLM.ToolKind.Custom)
    _ -> error("unknown tool kind #{name}")
  end
end

def optional_string(json: JSON.Value, key: String) -> Optional[String]
  case JSON.string(JSON.get(json, key).unwrap_or(JSON.null()))
    ok(text) -> some(text)
    error(_) -> none
  end
end

def optional(json: JSON.Value, key: String) -> Optional[JSON.Value]
  case JSON.get(json, key)
    ok(value) -> some(value)
    error(_) -> none
  end
end

def option_list[T](value: Optional[T]) -> List[T]
  case value
    some(v) -> [v]
    none -> []
  end
end

# An empty object when the file is missing or broken.
def side_settings(file: Ref) -> JSON.Value
  JSON.parse(file.port.read_text.call(settings_file(file.path)).unwrap_or("")).unwrap_or(JSON.object({}))
end

def settings_file(path: String) -> String = "#{path.slice(0, path.length - EXTENSION.length)}#{SETTINGS_EXTENSION}"

def side_field(side: JSON.Value, name: String) -> Optional[String]
  case field(side, name)
    ok(value) -> some(value)
    error(_) -> none
  end
end
