## Where a copy goes. The provider is picked the way Neovim does (`:h clipboard`): `tmux load-buffer -w -` inside tmux,
## a tool of the local display when not over SSH, else OSC 52, which the terminal may ignore and nobody can confirm. Pure,
## but for `host` and `run`.

import Client from "pkg/client/client"
import Protocol from "pkg/protocol/protocol"

RUN_MS = 3000
## The most a program is given: `Process.send_bytes` takes 1 MiB.
MAX_INPUT_BYTES = 1_000_000
## The most OSC 52 is sent: terminals and multiplexers cut a sequence at about 100 KB of base64.
MAX_OSC52_BYTES = 74_000

## What the machine offers: where the app runs, and which of the programs it could use are on the `PATH`.
struct Host
  tmux: Bool = false
  ssh: Bool = false
  wayland: Bool = false
  x11: Bool = false
  wsl: Bool = false
  macos: Bool = false
  tools: List[String] = []
end

## A program that copies: `name` is what the note says, `argv` starts it, and it reads the text from its input.
struct Method
  name: String
  argv: List[String]
  ## The input is UTF-16 with a byte order mark, which is how `clip.exe` reads text that is not ASCII.
  utf16: Bool = false
  ## A program to ask after a copy that worked, whose first line of output is kept (what tmux does with the text).
  check: List[String] = []
end

## `tmux` sets its buffer, and with `-w` (tmux 3.2 or later) the clipboard of the outer terminal through its own OSC 52,
## unless its `set-clipboard` is `off`, which `check` reads.
def tmux() -> Method
  Method(
    name: "tmux",
    argv: ["tmux", "load-buffer", "-w", "-"],
    check: ["tmux", "show-options", "-gv", "set-clipboard"],
  )
end

## The program of each tool that the local display uses, in the order they are tried (as Neovim's).
def tools() -> List[Method]
  [
    Method(name: "pbcopy", argv: ["pbcopy"]),
    Method(name: "wl-copy", argv: ["wl-copy"]),
    Method(name: "xclip", argv: ["xclip", "-selection", "clipboard"]),
    Method(name: "xsel", argv: ["xsel", "-ib"]),
    Method(name: "clip.exe", argv: ["clip.exe"], utf16: true),
  ]
end

## The method that the setting and the host pick, none for OSC 52.
def choose(setting: Protocol.ClipboardSetting, host: Host) -> Optional[Method]
  case setting.provider
    "osc52" -> none
    "tmux" -> some(tmux())
    "command" if not setting.command.empty? ->
      some(Method(name: setting.command[0].split("/").last, argv: setting.command))
    _ -> automatic(host)
  end
end

## What the machine offers, read from the environment and the `PATH`.
def detect() -> Host
  path = System.env("PATH").unwrap_or("").split(":").select { |dir| dir != "" }
  names = ["tmux"] + tools().map { |method| method.argv[0] }
  Host(
    tmux: set?("TMUX"),
    ssh: set?("SSH_TTY") or set?("SSH_CONNECTION") or set?("SSH_CLIENT"),
    wayland: set?("WAYLAND_DISPLAY"),
    x11: set?("DISPLAY"),
    wsl: set?("WSL_DISTRO_NAME") or set?("WSL_INTEROP"),
    macos: System.os() == "macos",
    tools: names.select { |name| path.any? { |dir| found?("#{dir}/#{name}") } },
  )
end

## What the program reads as input.
def input(method: Method, text: String) -> Bytes
  return text.bytes if not method.utf16

  Bytes.from_list([255, 254]).unwrap! + text.encode("utf-16le").unwrap!
end

## What the check of a method says after the program `result` ended well ("" when it has none or it failed).
def checked(run: Fn[List[String], Bytes, Result[String]], method: Method, result: Result[String]) -> String
  return "" if method.check.empty? or not result.ok?

  run.call(method.check, "".bytes).unwrap_or("")
end

## Runs the program with `input` and waits for it to end, 3 s at most (a program that runs longer is killed). Its output
## goes to a file that no child it leaves behind can hold open (xclip and wl-copy keep the clipboard in one, so their own
## end is the copy). The first line it wrote is what comes back, and what an error says after the exit code.
def run(argv: List[String], input: Bytes) -> Result[String]
  dir = "#{System.env("TMPDIR").unwrap_or("/tmp")}/finn-clipboard-#{System.pid}-#{Random.int(0, 999_999_999)}"
  try Dir.mkdir_private(dir)
  written = "#{dir}/output"
  ended = ended_with(argv, input, written)
  line = first_line(File.read_text(written).unwrap_or(""))
  _ = Path.remove(dir)
  case ended
    ok(0) -> ok(line)
    ok(code) if line == "" -> error("exit code #{code}")
    ok(code) -> error("exit code #{code}: #{line}")
    error(e) -> error(e.message)
  end
end

private

def ended_with(argv: List[String], input: Bytes, output: String) -> Result[Int]
  options = Process.Options(timeout_ms: RUN_MS, out: output, err: output)
  child = try Process.spawn(argv[0], argv.drop(1), options)
  sent = Process.send_bytes(child, input, RUN_MS)
  closed = Process.close_stdin(child, RUN_MS)
  code = Process.wait(child, RUN_MS)
  Process.close(child)
  case code
    ok(0) ->
      try sent
      try closed
      ok(0)
    _ -> code
  end
end

def first_line(text: String) -> String
  lines = text.split("\n").map { |line| line.strip }.select { |line| not line.empty? }
  return "" if lines.empty?

  Client.printable(lines[0].split("").take(100).join(""))
end

def set?(name: String) -> Bool = not System.env(name).unwrap_or("").empty?

def found?(path: String) -> Bool
  case File.stat(path)
    ok(info) -> info.kind == "file"
    error(_) -> false
  end
end

def wanted(host: Host) -> List[String]
  names: List[String] = []
  if host.macos
    names = names + ["pbcopy"]
  end

  if host.wayland
    names = names + ["wl-copy"]
  end

  if host.x11
    names = names + ["xclip", "xsel"]
  end

  if host.wsl
    names = names + ["clip.exe"]
  end

  names
end

# Over SSH, the tools of the display would fill the remote machine's clipboard: tmux's OSC 52 or none. Locally the
# display tool comes first (as Neovim's), since a terminal may ignore OSC 52 and tmux cannot say so; tmux is the way
# when there is no tool.
def automatic(host: Host) -> Optional[Method]
  in_tmux = host.tmux and host.tools.include?("tmux")
  return none if host.ssh and not in_tmux
  return some(tmux()) if host.ssh

  for name in wanted(host)
    next if not host.tools.include?(name)

    for method in tools()
      return some(method) if method.name == name
    end
  end

  return some(tmux()) if in_tmux

  none
end
