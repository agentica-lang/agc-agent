# Where a copy goes: the provider each environment picks, the notes that say what was done, and the run of a real
# program. The model with a fake `run` stands for the machine; no terminal.

import Client from "pkg/client/client"
import Protocol from "pkg/protocol/protocol"
import TUI from "pkg/tui/tui"
import App from "../src/app"
import Clipboard from "../src/clipboard"
import Select from "../src/select"
import Selecting from "../src/selecting"
import Tty from "../src/terminal"
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

# Over SSH, `tmux load-buffer -w` when inside tmux, else OSC 52. Locally, a tool of the display (Wayland before
# X, `xclip`
# before `xsel`) when it is installed, even inside tmux: a terminal may ignore the OSC 52 that tmux sends, and tmux
# cannot say so. Then tmux, else OSC 52.
def test_the_provider_follows_the_environment() -> Result[Void]
  Test.eq(
    [
      auto(Clipboard.Host(tmux: true, ssh: true, x11: true, tools: ["tmux", "xclip"])),
      auto(Clipboard.Host(tmux: true, ssh: true, tools: [])),
      auto(Clipboard.Host(tmux: true, x11: true, tools: ["tmux", "xclip"])),
      auto(Clipboard.Host(tmux: true, tools: ["tmux", "xclip"])),
      auto(Clipboard.Host(ssh: true, x11: true, tools: ["xclip"])),
      auto(Clipboard.Host(x11: true, tools: ["xclip", "xsel"])),
      auto(Clipboard.Host(x11: true, tools: ["xsel"])),
      auto(Clipboard.Host(x11: true, wayland: true, tools: ["xclip", "wl-copy"])),
      auto(Clipboard.Host(x11: true, tools: [])),
      auto(Clipboard.Host(macos: true, tools: ["pbcopy"])),
      auto(Clipboard.Host(wsl: true, tools: ["clip.exe"])),
      auto(Clipboard.Host(tools: ["xclip", "wl-copy"])),
    ],
    ["tmux", "osc52", "xclip", "tmux", "osc52", "xclip", "xsel", "wl-copy", "osc52", "pbcopy", "clip.exe", "osc52"],
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
  # `command` with no program is the automatic choice.
  try Test.eq(named(Clipboard.choose(Protocol.ClipboardSetting(provider: "command"), host)), "xclip")
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
def machine(host: Clipboard.Host, result: Result[String], checked: String = "", text: String = TEXT) -> Machine
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
    entries: Transcript.from_history([Protocol.Message(role: Protocol.Role.User, text: text)]),
    selection: some(everything),
    host: host,
    write: ->(sent: String) { _ = written.send(sent, 0) },
    run: ->(argv: List[String], input: Bytes) {
      _ = ran.send("#{argv.join(" ")} <- #{String.from_bytes(input).unwrap_or("")}", 0)
      return ok(checked) if argv.size > 1 and argv[1] == "display"

      result
    },
  )

  Machine(model: model, ran: ran, written: written)
end

# The model after the copy: the commands it started run, and what they give back goes through `update`.
def finished(rig: Machine) -> App.Model
  copied = Selecting.copied(rig.model)
  done = copied.with(effects: [])
  for cmd in copied.effects
    case cmd
      TUI.Cmd.Run(work) -> done = App.update(done, work.call()).model
      _ -> nil
    end
  end

  done
end

def note(model: App.Model) -> String = model.entries.last.text

# A program that copies: the text goes to it, nothing goes to the terminal, and the note names the program.
def test_a_tool_that_copies_is_named_in_the_note() -> Result[Void]
  rig = machine(Clipboard.Host(x11: true, tools: ["xclip"]), ok(""))
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
  Test.eq(rig.written.recv(0), ok(Tty.osc52(TEXT)))
end

# tmux sends the text on only to a terminal with the `clipboard` feature: the note says when its list has none, and
# says `(tmux)` when it has it or when tmux could not be asked.
def test_tmux_without_the_clipboard_feature_says_the_buffer_only() -> Result[Void]
  host = Clipboard.Host(tmux: true, ssh: true, tools: ["tmux"])
  without = finished(machine(host, ok(""), checked: "256,RGB,mouse"))
  try Test.eq(
    note(without),
    "copied 11 characters to the tmux buffer; this terminal may not get it (no clipboard feature in tmux)",
  )

  bare = finished(machine(host, ok(""), checked: ""))
  try Test.eq(
    note(bare),
    "copied 11 characters to the tmux buffer; this terminal may not get it (no clipboard feature in tmux)",
  )

  with = finished(machine(host, ok(""), checked: "256,clipboard,ccolour"))
  try Test.eq(note(with), "copied 11 characters (tmux)")
  unknown = finished(machine(host, ok(""), checked: Clipboard.UNKNOWN))
  Test.eq(note(unknown), "copied 11 characters (tmux)")
end

# The cap of 74000 bytes is the one of OSC 52: a program takes more, and a failed program leaves a selection that does
# not fit the sequence not sent, with the reason said.
def test_the_osc52_cap_applies_only_to_the_sequence() -> Result[Void]
  word = (0...39).to_a.map { |_| "é" }.join("")
  big = (0...1000).to_a.map { |_| word }.join(" ")
  host = Clipboard.Host(x11: true, tools: ["xclip"])
  rig = machine(host, ok(""), text: big)
  try Test.eq(Selecting.copied(rig.model).effects.size, 1)
  method = Clipboard.choose(Protocol.ClipboardSetting(), host).unwrap!
  failed = Selecting.finished(rig.model, big, method, error("exit code 1: no display"), "")
  try Test.assert(
    failed.entries.last.text.start_with?("xclip failed (exit code 1: no display); selection too large"),
    note(failed),
  )

  Test.error?(rig.written.recv(0))
end

# With no tool to use, the terminal gets the sequence and the note says it was sent, not that it was copied.
def test_osc52_says_sent_not_copied() -> Result[Void]
  rig = machine(Clipboard.Host(ssh: true, x11: true, tools: ["xclip"]), ok(""))
  done = finished(rig)
  try Test.eq(note(done), "sent 11 characters to the terminal (OSC 52)")
  try Test.error?(rig.ran.recv(0))
  Test.eq(rig.written.recv(0), ok(Tty.osc52(TEXT)))
end

# The real run: the text reaches the program's input, a failing or missing program is an error, and a tool that leaves
# a child holding the clipboard (xclip, wl-copy) ends the run as its parent exits. The child sleeps past the run's
# time limit, so waiting for it would fail the test.
def test_run_gives_the_text_to_a_real_program() -> Result[Void]
  dir = "#{System.env("TMPDIR").unwrap_or("/tmp")}/clipboard-#{Random.int(0, 999999999)}"
  try Dir.mkdir_private(dir)
  copy = "#{dir}/copy"
  try Test.eq(Clipboard.run(["sh", "-c", "cat > \"$1\"", "sh", copy], "tmux é".bytes), ok(""))
  try Test.eq(File.read_text(copy), ok("tmux é"))
  try Test.eq(Clipboard.run(["sh", "-c", "cat > /dev/null; exit 3"], "x".bytes), error("exit code 3"))
  try Test.eq(Clipboard.run(["sh", "-c", "cat > /dev/null; sleep 5 & exit 0"], "x".bytes), ok(""))
  # The first line the program wrote comes back: from a good end, and in the error of a bad one.
  try Test.eq(Clipboard.run(["sh", "-c", "cat > /dev/null; echo external"], "x".bytes), ok("external"))
  try Test.eq(
    Clipboard.run(["sh", "-c", "cat > /dev/null; echo 'no display' >&2; exit 1"], "x".bytes),
    error("exit code 1: no display"),
  )

  missing = Clipboard.run(["no-such-clipboard-tool"], "x".bytes)
  _ = Path.remove(dir)
  Test.eq(missing.ok?, false)
end
