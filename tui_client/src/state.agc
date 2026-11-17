## The state of the full screen, pure: the model, its messages, and the small steps every part of `update` takes.

import Client from "pkg/client/client"
import Protocol from "pkg/protocol/protocol"
import TUI from "pkg/tui/tui"
import Approvals from "approvals"
import Args from "args"
import Input from "input"
import Picker from "picker"
import Prompt from "prompt"
import Theme from "theme"
import Transcript from "transcript"
import Yolo from "pkg/client/yolo"

WAIT_MS = 3_600_000
SPINNER = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
SPIN_MS = 80

struct Model
  ## The calls on the server (`Client.http_backend`; a test gives its own).
  backend: Client.Backend
  id: String
  ## The folder of the session.
  cwd: String = ""
  ## What `/new` makes a session with.
  options: Args.Options
  signals: Channel[System.Signal]
  width: Int
  height: Int
  entries: List[Transcript.Entry] = []
  prompt: String = ""
  ## The cursor in the prompt, a character index (clamped to the text when used).
  cursor: Int = 0
  ## The column Up and Down keep while they move the cursor across shorter rows.
  goal_column: Optional[Int] = none
  ## Rows above the bottom of the transcript, 0 to follow its end.
  scroll: Int = 0
  turn: Bool = false
  ## A `!` command of the session runs.
  shell: Bool = false
  stopping: Bool = false
  ## The reader of the event stream and the channel it fills.
  stream: Optional[Task[Void]] = none
  feed: Optional[Channel[Client.Item]] = none
  generation: Int = 0
  last_event_id: Int = 0
  ## The highest event id already drawn, so a replay draws nothing twice.
  shown_id: Int = 0
  reconnects: Int = 0
  ## `resync` events in a row, with no other event between.
  resyncs: Int = 0
  ## The messages to send, in order, one at a time: the first is on its way. The stream waits in `held` until every
  ## reply came, so its events meet the state the replies give (the turn this client started, the message it queued).
  outbox: List[String] = []
  held: List[Client.Item] = []
  ## Messages for after the turn (Alt+Enter), sent together when it ends.
  follow_ups: List[String] = []
  ## The prompts sent, oldest first, and the one Up shows (none: the prompt being typed).
  history: List[String] = []
  recall: Optional[Int] = none
  ## The large pastes behind the tokens of the prompt, until it is sent.
  pastes: List[String] = []
  ## The files of the session's folder once read, the selected one of the `@` or `/` list, the first one it shows, and
  ## the word that Esc closed.
  files: Optional[List[String]] = none
  reading_files: Bool = false
  ## The choices of the argument of the command in the prompt, read from the server when its argument starts.
  arguments: Optional[Input.Arguments] = none
  reading_arguments: Bool = false
  ## The command whose choices could not be read, not asked again until the command changes.
  arguments_failed: Optional[String] = none
  ## The last list read was cut: said once, until a whole one comes.
  files_cut: Bool = false
  ## After a read that timed out, while the server may still walk the folder, `@` asks again only from this time on.
  files_again_at: Int = 0
  mention_selected: Int = 0
  mention_top: Int = 0
  mention_closed: Optional[Int] = none
  ## Esc came before the turn of a message sent started: the turn stops once the reply says it did.
  stop_wanted: Bool = false
  ## How many times a session was opened, so the reply to a send made before is dropped.
  opened: Int = 0
  ## The picker of `/resume`, `/tree` or `/fork`, open over the prompt.
  picker: Optional[Picker.Picker] = none
  ## The provider and model of the session, as `provider/model`, for the status line and the `/model` picker.
  serving: String = ""
  ## The session's profile for the status line; empty for the built-in `build`.
  profile: String = ""
  ## The slash commands of the session's folder `custom_dir`, for the suggestions after `/` and `/help`; read again
  ## when a session of another folder opens.
  custom: List[Client.Usage] = []
  custom_dir: Optional[String] = none
  ## The tree the picker of `/tree` or `/fork` showed last, whose numbers `/tree N` and `/fork N` name.
  listed: Optional[Protocol.SessionTree] = none
  ## A branch, a fork or a copy is on its way: nothing is sent until its reply.
  moving: Bool = false
  ## The prompt holds the message a move went back before, selected: typing replaces it.
  prefilled: Bool = false
  ## The provider whose key the prompt asks for, and the key typed so far: drawn as dots, kept nowhere else, and
  ## cleared once it is sent or the ask is closed.
  key_for: Optional[String] = none
  secret: String = ""
  ## The login of `key_for` asks for a base URL, shown as typed, not a key.
  asking_url: Bool = false
  ## A login offered at the first start: closing it stores an empty key file, so it is offered once. With
  ## `login_only` (`finn login`), the app ends after the login.
  first_login: Bool = false
  login_only: Bool = false
  ## The model `/model` set, until the turn after it ends: a failed call there gets a warning.
  new_model: Optional[String] = none
  yolo: Yolo.Yolo
  ## The thinking of the model is drawn.
  thinking: Bool = false
  ## The output of the tool calls is shown whole.
  tools: Bool = false
  ## The thinking level the rules show, none for the model's default; the server's own is `confirmed`.
  effort: Optional[String] = none
  confirmed: Optional[String] = none
  ## The level whose change is on its way: one at a time, and the reply sends the latest one wanted.
  level_sending: Optional[String] = none
  ## The frame of the spinner while a turn runs.
  spin: Int = 0
  approvals: Approvals.Panel
  ## The colors of the screen.
  theme: Theme.Theme
  ## The `usage` of the session's last model call, the git branch of its folder and the home folder, for the footer.
  usage: Optional[Protocol.Usage] = none
  branch: String = ""
  home: String = ""
  ## The editor of Ctrl+G (`$VISUAL`, else `$EDITOR`), and whether it has the terminal now.
  editor: String = ""
  editing: Bool = false
  ## The private folder the edits of Ctrl+G go in; "" when there is none.
  edits: String = ""
  ## The monotonic ms and the wall clock s of the message being handled.
  now: Int = 0
  clock_s: Int = 0
  ## The commands the message being handled starts.
  effects: List[TUI.Cmd[Msg]] = []
  exit: Optional[Int] = none
  ## Why the client ends with an error.
  failure: Optional[String] = none
end

enum Msg
  Key(TUI.Event)
  ## A signal, none when the wait ended without one.
  Signal(Optional[System.Signal])
  ## The items of the stream of a generation, so the messages of an old stream are dropped.
  Stream(Int, List[Client.Item])
  ## The reply of the server to the answer of an approval.
  Answered(String, Result[Void])
  ## A note for the transcript (a compaction's end).
  Note(String)
  ## The server was checked again before the stream of a generation is read again.
  Rechecked(Int, Result[Void])
  ## The reply to a message sent: the `opened` count when it was sent, and the text.
  Sent(Int, String, Result[Protocol.MessageAccepted])
  ## The reply to a stop.
  Stopped(String, Result[Bool])
  ## The spinner moves on.
  Spin
  ## The reply to a change of the thinking level.
  Leveled(Result[Void])
  ## The reply to a branch, a fork or a copy: the session to go on in.
  Moved(Result[Protocol.Branched])
  ## The reply to a login, with no key in it.
  LoggedIn(String, Result[Protocol.LoginStatus])
  ## The files of the session's folder, for the `opened` count when they were asked.
  Files(Int, Result[Protocol.FileList])
  ## The choices of a command's argument, for the `opened` count when they were asked.
  Arguments(Int, String, Result[Input.Arguments])
  ## The text the editor of Ctrl+G saved.
  Edited(Result[String])
  ## Where `/export` wrote the session.
  Exported(Result[String])
  ## The reply to a `!` command: the command, and whether it runs.
  ShellSent(String, Result[Protocol.ShellAccepted])
  ## The git branch of the session's folder, for the `opened` count when it was read.
  Branch(Int, String)
end

## The model before the session is opened.
def seed(
  backend: Client.Backend,
  options: Args.Options,
  signals: Channel[System.Signal],
  width: Int,
  height: Int,
) -> Model
  Model(
    backend: backend,
    id: "",
    options: options,
    signals: signals,
    width: width,
    height: height,
    thinking: options.thinking,
    approvals: Approvals.Panel(),
    yolo: Yolo.Yolo(on: options.yolo),
    theme: Theme.default(),
    home: System.env("HOME").unwrap_or(""),
    editor: editor_of(System.env("VISUAL").unwrap_or(""), System.env("EDITOR").unwrap_or("")),
    now: Time.monotonic_ms,
    clock_s: Time.now_ms / 1000,
  )
end

def effect(app: Model, cmd: TUI.Cmd[Msg]) -> Model = app.with(effects: app.effects.push(cmd))

def listen(signals: Channel[System.Signal]) -> TUI.Cmd[Msg]
  TUI.Cmd.Run(
    -> {
      case signals.recv(WAIT_MS)
        ok(signal) -> Msg.Signal(some(signal))
        error(_) -> Msg.Signal(none)
      end
    },
  )
end

def cursor(app: Model) -> Int = Prompt.clamp(app.prompt, app.cursor)

def ctrl_c?(event: TUI.Event) -> Bool
  case event
    TUI.Event.Key(TUI.Key.Ctrl("c"), _) -> true
    _ -> false
  end
end

def option_list[T](value: Optional[T]) -> List[T]
  case value
    some(v) -> [v]
    none -> []
  end
end

def page(app: Model) -> Int = [app.height / 2, 1].max.unwrap!

def scrolled(app: Model, rows: Int) -> Model = app.with(scroll: [app.scroll + rows, 0].max.unwrap!)

def note_entry(text: String) -> Transcript.Entry = Transcript.Entry(kind: Transcript.Kind.Notice, text: text)

## A command that failed says why; the session goes on.
def tried(app: Model, result: Result[Model]) -> Model
  case result
    ok(next_app) -> next_app
    error(e) -> noted(app, "error: #{e.message}")
  end
end

def noted(app: Model, text: String) -> Model = app.with(entries: Transcript.note(app.entries, text))

def busy?(app: Model) -> Bool = app.turn or app.shell

def folds(app: Model) -> Transcript.Folds = Transcript.Folds(thinking: app.thinking, tools: app.tools)

## A level wanted while its change is on its way stays across a new read of the session.
def wanted_level(app: Model, server: Optional[String]) -> Optional[String]
  return app.effort if app.level_sending.some?

  server
end

def level_of(effort: String) -> Optional[String]
  return none if effort == Protocol.EFFORT_DEFAULT

  some(effort)
end

def level_name(level: Optional[String]) -> String = level.unwrap_or(Protocol.EFFORT_DEFAULT)

def serving_of(session: Protocol.Session) -> String = "#{session.provider}/#{session.model}"

## The editor of Ctrl+G: `$VISUAL`, else `$EDITOR`; "" when neither is set.
def editor_of(visual: String, editor: String) -> String
  return visual.strip if not visual.strip.empty?

  editor.strip
end
