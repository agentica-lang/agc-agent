## A session's branch for a file: its messages in order, each tool call in short (its name, what it was called on and
## whether it worked, without its output), and the todo list as it stands at the end of the branch.

import Protocol from "pkg/protocol/protocol"
import Store from "store"

def of(file: Store.Ref) -> Result[Protocol.SessionExport]
  header = try Store.header(file)
  entries: List[Protocol.ExportEntry] = []
  # Where each tool call is in `entries`, until its result comes.
  calls: Map[String, Int] = {}
  todos: List[Protocol.Todo] = []
  for json in try Store.branch_records(file)
    case JSON.string(JSON.get(json, "type").unwrap_or(JSON.null())).unwrap_or("")
      "user" ->
        entries = entries.push(message("user", text_of(json, "typed").unwrap_or(text_of(json, "text").unwrap_or(""))))
      "queued" -> entries = entries.push(message("user", text_of(json, "text").unwrap_or("")))
      "answer" -> entries = entries.push(message("assistant", text_of(json, "text").unwrap_or("")))
      "compaction" -> entries = entries.push(message("compaction", ""))
      "event" ->
        case event_of(json)
          some(Protocol.Event.ToolStarted(started)) ->
            calls = calls.put(started.call_id, entries.size)
            entries = entries.push(Protocol.ExportEntry(kind: "tool", tool: started.name, text: started.summary))
          some(Protocol.Event.ToolFinished(finished)) ->
            if calls.key?(finished.call_id)
              at = calls.get(finished.call_id).unwrap!
              entries = entries.set(at, entries[at].with(ok: some(finished.ok)))
            end

          some(Protocol.Event.Todos(list)) -> todos = list.todos
          _ -> nil
        end

      _ -> nil
    end
  end

  title = entries.select { |entry| entry.kind == "user" }.map { |entry| entry.text.split("\n")[0] }.take(1).join("")
  ok(
    Protocol.SessionExport(id: header.id, title: title, created_ms: header.created_ms, entries: entries, todos: todos),
  )
end

private

def message(kind: String, text: String) -> Protocol.ExportEntry = Protocol.ExportEntry(kind: kind, text: text)

def text_of(json: JSON.Value, key: String) -> Optional[String]
  case JSON.string(JSON.get(json, key).unwrap_or(JSON.null()))
    ok(text) -> some(text)
    error(_) -> none
  end
end

# The event of an `event` record; none when it does not decode.
def event_of(json: JSON.Value) -> Optional[Protocol.Event]
  name = text_of(json, "name").unwrap_or("")
  case JSON.get(json, "data")
    ok(data) ->
      case Protocol.decode_event(name, JSON.encode(data))
        ok(event) -> some(event)
        error(_) -> none
      end

    error(_) -> none
  end
end
