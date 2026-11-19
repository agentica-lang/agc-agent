# The prebuilt library of bash, end to end (make prebuilt-e2e): a fresh project fetches bash by `subdir` from a copy of
# this repository, through git's `insteadOf`, and the copy's manifest names the library that `make native-lib` built,
# served on 127.0.0.1. `update` must download it and check its sha256, and a run must parse a line with it while
# CC=false, so no compiler runs. The copy holds the files of bash/ that git tracks, as they are in the working tree.
#
# Arguments: the agentica binary and the folder of the library.

import HTTP from "std/http"

REPOSITORY = "https://github.com/agentica-lang/agc-agent"
TAG = "e2e"
TARGETS = ["linux-x86_64", "linux-arm64", "macos-x86_64", "macos-arm64", "windows-x86_64"]
EXTENSIONS = [".so", ".dylib", ".dll"]
LINE = "ls -la | grep x"
WANTED = "ls grep"
RUN_MS = 300_000
CHUNK = 1_048_576

def main() -> Void
  args = System.args()
  if args.size != 2
    IO.warn("usage: prebuilt_e2e.agc AGENTICA LIBRARY_FOLDER")
    System.exit(2)
  end

  work = "#{System.env("TMPDIR").unwrap_or("/tmp")}/finn-prebuilt-e2e-#{System.pid()}"
  result = check(args[0], args[1], work)
  _ = Path.remove(work)
  case result
    ok(_) -> puts("prebuilt-e2e: a fresh project used the downloaded library of bash, with no compiler")
    error(message) ->
      IO.warn("prebuilt-e2e: #{message}")
      System.exit(1)
  end
end

private

def check(agentica: String, library_folder: String, work: String) -> Result[Void]
  try Dir.mkdir_private(work)
  library = try read_all(try library_file(library_folder))
  requests: Channel[String] = Channel.new(16)
  server = try HTTP.serve("127.0.0.1", 0, HTTP.app(->(request: HTTP.Request) { answer(request, library, requests) }))
  repository = try copy_bash("#{work}/repository", "#{work}/bash.tar")
  try prebuilt(agentica, repository, HTTP.local_port(server), OpenSSL.Digest.sha256_hexdigest(library))
  try git(repository, ["init", "-q"])
  try git(repository, ["add", "-A"])
  try git(
    repository,
    ["-c", "user.name=e2e", "-c", "user.email=e2e@localhost", "-c", "commit.gpgsign=false", "commit", "-qm", "e2e"],
  )

  try git(repository, ["tag", TAG])

  project = try fresh_project(work, repository)
  env = {
    "GIT_CONFIG_GLOBAL": "#{work}/gitconfig",
    "GIT_CONFIG_NOSYSTEM": "1",
    "XDG_CACHE_HOME": "#{work}/cache",
    "CC": "false",
  }

  _ = try run(agentica, ["--native-prebuilt-only=bash", "update"], project, env)
  out = try run(agentica, ["--native-prebuilt-only=bash", "main.agc"], project, env)
  HTTP.close_server(server)

  return error("the run printed #{out.strip.inspect}, not #{WANTED.inspect}") if out.strip != WANTED

  served: List[String] = []
  while !Channel.empty?(requests)
    served = served.push(try Channel.recv(requests, 1000))
  end

  return error("the library was asked for #{served.size} times: #{served.join(" ")}") if served.size != 1

  cache = "#{work}/cache/agentica/pkg"
  return error("#{cache}/native-build exists: a compiler ran") if File.stat("#{cache}/native-build").ok?

  nothing: List[String] = []
  stored = Dir.list("#{cache}/native-prebuilt").unwrap_or(nothing)
  return error("#{cache}/native-prebuilt holds #{stored.inspect}, not one library") if stored.size != 1

  ok()
end

def answer(request: HTTP.Request, library: Bytes, requests: Channel[String]) -> Result[HTTP.Response]
  _ = Channel.send(requests, request.path, 1000)
  return ok(HTTP.Response(status: 404, headers: [], body: "".bytes)) if !request.path.start_with?("/libbash-")

  ok(HTTP.Response(status: 200, headers: [], body: library))
end

def library_file(folder: String) -> Result[String]
  names = try Dir.list(folder)
  found = names.select { |name| EXTENSIONS.any? { |extension| name.end_with?(extension) } }
  return error("#{folder} holds no library of bash (make native-lib)") if found.empty?

  ok("#{folder}/#{found[0]}")
end

def read_all(path: String) -> Result[Bytes]
  file = try File.open(path)
  pieces: List[Bytes] = []
  piece = try File.read_bytes(file, CHUNK)
  while piece.size > 0
    pieces = pieces.push(piece)
    piece = try File.read_bytes(file, CHUNK)
  end

  try File.close(file)
  ok(Bytes.concat(pieces))
end

# The files of bash/ that git tracks, as they are in the working tree, in a new folder: what a fetch of a commit with
# them sees.
def copy_bash(repository: String, archive: String) -> Result[String]
  listed = "#{archive}.files"
  try File.write_text(listed, try run("git", ["ls-files", "-z", "bash"], ".", {}))
  _ = try run("tar", ["-cf", archive, "--null", "-T", listed], ".", {})
  try Dir.mkdir(repository)
  _ = try run("tar", ["-xf", archive, "-C", repository], ".", {})
  large = try run("find", [repository, "-type", "f", "-size", "+#{CHUNK}c"], ".", {})
  return error("a file of bash/ is over 1 MiB, which a fetch refuses: #{large.strip}") if large.strip != ""

  ok(repository)
end

# The manifest of the copy names the served library for every target, with the source key of the copy, in place of the
# rows of the release (the table is the last of the manifest).
def prebuilt(agentica: String, repository: String, port: Int, sha256: String) -> Result[Void]
  printed = try run(agentica, ["native", "source", "bash"], "#{repository}/bash", {})
  source = try field(printed, "source")
  api = try field(printed, "api")
  rows = TARGETS.map { |target| "#{target} = \"#{sha256}\"" }.join(", ")
  manifest = "#{repository}/bash/agentica.toml"
  text = (try File.read_text(manifest)).split("\n[native.bash.prebuilt]")[0]
  table = <<~TOML

    [native.bash.prebuilt]
    url = "http://127.0.0.1:#{port}/lib{name}-{api}-{target}{ext}"
    source = "#{source}"
    api = "#{api}"
    sha256 = { #{rows} }
  TOML
  File.write_text(manifest, text + table)
end

def field(printed: String, name: String) -> Result[String]
  for line in printed.split("\n")
    words = line.strip.split(" ")
    return ok(words[1]) if words.size == 2 and words[0] == name
  end

  error("`agentica native source bash` printed no #{name}: #{printed.inspect}")
end

def fresh_project(work: String, repository: String) -> Result[String]
  project = "#{work}/project"
  try Dir.mkdir(project)
  try File.write_text("#{work}/gitconfig", "[url \"file://#{repository}\"]\n\tinsteadOf = #{REPOSITORY}\n")
  try File.write_text(
    "#{project}/agentica.toml",
    <<~TOML,
    name = "fresh"
    agentica = "0.35.0"

    [dependencies]
    bash = { git = "#{REPOSITORY}", subdir = "bash", tag = "#{TAG}" }
  TOML
  )

  try File.write_text(
    "#{project}/main.agc",
    <<~AGC,
    import Bash from "pkg/bash/bash"

    def main() -> Void
      parsed = Bash.parse(#{LINE.inspect}).unwrap!
      puts(parsed.commands.map { |command| command.words[0].text }.join(" "))
    end
  AGC
  )

  ok(project)
end

def git(folder: String, args: List[String]) -> Result[Void]
  _ = try run("git", ["-C", folder].concat(args), ".", {})
  ok()
end

# The stdout of a command that must end with 0; its stderr is in the error.
def run(command: String, args: List[String], folder: String, env: Map[String, String]) -> Result[String]
  process = try Process.spawn_captured(command, args, Process.Options(timeout_ms: RUN_MS, chdir: folder, env: env))
  output = try Process.output(process, RUN_MS)
  status = try Process.wait(process, RUN_MS)
  return error("#{command} #{args.join(" ")} exited with #{status}: #{output.stderr.strip}") if status != 0

  ok(output.stdout)
end
