# Where a copy goes: the provider each environment picks, the notes that say what was done, and the run of a real
# program. The model with a fake `run` stands for the machine; no terminal.

import Client from "pkg/client/client"
import Protocol from "pkg/protocol/protocol"
import TUI from "pkg/tui/tui"
import App from "../src/app"
import Clipboard from "../src/clipboard"
import Select from "../src/select"
import Selecting from "../src/selecting"
import Terminal from "../src/terminal"
import Transcript from "../src/transcript"
import Args from "../src/args"

TEXT = "hello world"

struct Machine
  model: App.Model
  ran: Channel[String]
  written: Channel[String]
end

def named(method: Optional[Clipboard.Method]) -> String
  case method
    some(found) -> found.name
    none -> "osc52"
  end
end

def auto(host: Clipboard.Host) -> String = named(Clipboard.choose(Protocol.ClipboardSetting(), host))

# `tmux load-buffer -w` inside tmux, even over SSH or with a display; a tool of the local display (Wayland before X,
# `xclip` before `xsel`) only when not over SSH and when it is installed; else OSC 52.
def test_the_provider_follows_the_environment() -> Result[Void]
  Test.eq(
    [
      auto(Clipboard.Host(tmux: true, ssh: true, x11: true, tools: ["tmux", "xclip"])),
      auto(Clipboard.Host(tmux: true, ssh: true, tools: [])),
      auto(Clipboard.Host(ssh: true, x11: true, tools: ["xclip"])),
      auto(Clipboard.Host(x11: true, tools: ["xclip", "xsel"])),
      auto(Clipboard.Host(x11: true, tools: ["xsel"])),
      auto(Clipboard.Host(x11: true, wayland: true, tools: ["xclip", "wl-copy"])),
      auto(Clipboard.Host(x11: true, tools: [])),
      auto(Clipboard.Host(macos: true, tools: ["pbcopy"])),
      auto(Clipboard.Host(wsl: true, tools: ["clip.exe"])),
      auto(Clipboard.Host(tools: ["xclip", "wl-copy"])),
    ],
    ["tmux", "osc52", "osc52", "xclip", "xsel", "wl-copy", "osc52", "pbcopy", "clip.exe", "osc52"],
  )
end

# The setting forces a provider whatever the environment says; `command` runs the program the user named.
def test_the_setting_forces_a_provider() -> Result[Void]
  host = Clipboard.Host(tmux: true, x11: true, tools: ["tmux", "xclip"])
  forced = ["osc52", "tmux", "command"].map do |provider|
    command = ["/opt/bin/mycopy", "--all"]
    method = Clipboard.choose(Protocol.ClipboardSetting(provider: provider, command: command), host)
    named(method)
  end

  try Test.eq(forced, ["osc52", "tmux", "mycopy"])
  try Test.eq(named(Clipboard.choose(Protocol.ClipboardSetting(provider: "tmux"), Clipboard.Host())), "tmux")
  Test.eq(
    Clipboard.choose(Protocol.ClipboardSetting(provider: "command", command: ["x", "-y"]), host).unwrap!.argv,
    ["x", "-y"],
  )
end

# `clip.exe` reads UTF-16 with a byte order mark; the others read the text as it is.
def test_clip_exe_gets_utf16() -> Result[Void]
  clip = Clipboard.Method(name: "clip.exe", argv: ["clip.exe"], utf16: true)
  plain = Clipboard.Method(name: "xclip", argv: ["xclip"])
  try Test.eq(Clipboard.input(clip, "aé😀").to_a, [255, 254, 97, 0, 233, 0, 61, 216, 0, 222])
  Test.eq(Clipboard.input(plain, "aé").to_a, "aé".bytes.to_a)
end

# The model with `text` selected, on a machine whose programs end as `result` says; what they were asked and what
# the app wrote to the terminal come out on the channels.
def machine(host: Clipboard.Host, result: Result[Void]) -> Machine
  ran: Channel[String] = Channel.new(4)
  written: Channel[String] = Channel.new(4)
  options = Args.Options(
    state_dir: none,
    server_command: none,
    session: none,
    cwd: none,
    model: none,
    api: none,
    thinking: false,
  )

  everything = Select.Selection(anchor: Select.Cell(row: 0, col: 0), head: Select.Cell(row: 100_000, col: 0))
  model = App.seed(Client.unreachable_backend(), options, Channel.new(1), 40, 12).with(
    entries: Transcript.from_history([Protocol.Message(role: Protocol.Role.User, text: TEXT)]),
    selection: some(everything),
    host: host,
    write: ->(sent: String) { _ = written.send(sent, 0) },
    run: ->(argv: List[String], input: Bytes) {
      _ = ran.send("#{argv.join(" ")} <- #{String.from_bytes(input).unwrap_or("")}", 0)
      result
    },
  )

  Machine(model: model, ran: ran, written: written)
end

# The messages the commands of a step give back, and the model it left.
def finished(rig: Machine) -> App.Model
  copied = Selecting.copied(rig.model)
  done = copied
  for cmd in copied.effects
    case cmd
      TUI.Cmd.Run(work) ->
        case work.call()
          App.Msg.Copied(text, method, result) -> done = Selecting.finished(copied, text, method, result)
          _ -> nil
        end

      _ -> nil
    end
  end

  done
end

def note(model: App.Model) -> String = model.entries.last.text

# A program that copies: the text goes to it, nothing goes to the terminal, and the note names the program.
def test_a_tool_that_copies_is_named_in_the_note() -> Result[Void]
  rig = machine(Clipboard.Host(x11: true, tools: ["xclip"]), ok())
  done = finished(rig)
  try Test.eq(note(done), "copied 11 characters (xclip)")
  try Test.eq(rig.ran.recv(0), ok("xclip -selection clipboard <- #{TEXT}"))
  Test.error?(rig.written.recv(0))
end

# A tool that fails does not leave the note saying "copied": the terminal is asked instead, and the note says both.
def test_a_tool_that_fails_falls_back_to_osc52_and_says_so() -> Result[Void]
  rig = machine(Clipboard.Host(tmux: true, tools: ["tmux"]), error("exit code 1"))
  done = finished(rig)
  try Test.eq(note(done), "tmux failed (exit code 1); sent 11 characters to the terminal (OSC 52)")
  try Test.eq(rig.ran.recv(0), ok("tmux load-buffer -w - <- #{TEXT}"))
  Test.eq(rig.written.recv(0), ok(Terminal.osc52(TEXT)))
end

# With no tool to use, the terminal gets the sequence and the note says it was sent, not that it was copied.
def test_osc52_says_sent_not_copied() -> Result[Void]
  rig = machine(Clipboard.Host(ssh: true, x11: true, tools: ["xclip"]), ok())
  done = finished(rig)
  try Test.eq(note(done), "sent 11 characters to the terminal (OSC 52)")
  try Test.error?(rig.ran.recv(0))
  Test.eq(rig.written.recv(0), ok(Terminal.osc52(TEXT)))
end

# The real run: the text reaches the program's input, a failing or missing program is an error, and a tool that leaves
# a child holding the clipboard (xclip, wl-copy) ends the run as its parent exits. The child sleeps past the run's
# time limit, so waiting for it would fail the test.
def test_run_gives_the_text_to_a_real_program() -> Result[Void]
  dir = "#{System.env("TMPDIR").unwrap_or("/tmp")}/clipboard-#{Random.int(0, 999999999)}"
  try Dir.mkdir_private(dir)
  copy = "#{dir}/copy"
  try Test.eq(Clipboard.run(["sh", "-c", "cat > \"$1\"", "sh", copy], "tmux é".bytes), ok())
  try Test.eq(File.read_text(copy), ok("tmux é"))
  try Test.eq(Clipboard.run(["sh", "-c", "cat > /dev/null; exit 3"], "x".bytes), error("exit code 3"))
  try Test.eq(Clipboard.run(["sh", "-c", "cat > /dev/null; sleep 5 & exit 0"], "x".bytes), ok())
  missing = Clipboard.run(["no-such-clipboard-tool"], "x".bytes)
  _ = Path.remove(dir)
  Test.eq(missing.ok?, false)
end
