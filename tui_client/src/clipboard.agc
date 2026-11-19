## Where a copy goes. The provider is picked the way Neovim does (`:h clipboard`): `tmux load-buffer -w -` inside tmux,
## a tool of the local display when not over SSH, else OSC 52, which the terminal may ignore and nobody can confirm. Pure,
## but for `host` and `run`.

import Protocol from "pkg/protocol/protocol"

RUN_MS = 3000

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
end

## `tmux` sets its buffer, and with `-w` the clipboard of the outer terminal through its own OSC 52.
def tmux() -> Method = Method(name: "tmux", argv: ["tmux", "load-buffer", "-w", "-"])

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
    "command" -> some(Method(name: setting.command[0].split("/").last, argv: setting.command))
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

## Runs the program with `input` and waits for it to end. A tool that keeps the clipboard (xclip, wl-copy) does it in a
## child it leaves behind, so its own end is the copy; its output goes nowhere, since that child would hold a pipe open.
def run(argv: List[String], input: Bytes) -> Result[Void]
  quiet = Process.Options(timeout_ms: RUN_MS, out: "/dev/null", err: "/dev/null")
  child = try Process.spawn(argv[0], argv.drop(1), quiet)
  try Process.send_bytes(child, input, RUN_MS)
  try Process.close_stdin(child, RUN_MS)
  code = try Process.wait(child, RUN_MS)
  Process.close(child)
  return error("exit code #{code}") if code != 0

  ok()
end

private

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

def automatic(host: Host) -> Optional[Method]
  return some(tmux()) if host.tmux and host.tools.include?("tmux")
  return none if host.ssh

  for name in wanted(host)
    next if not host.tools.include?(name)

    for method in tools()
      return some(method) if method.name == name
    end
  end

  none
end
