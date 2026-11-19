## The pinned worker binary: `scripts/monty` of the pydantic-monty-runtime wheel of this platform, downloaded on first
## use with its sha256 checked, and only that one member extracted. The wheel is untrusted until its hash matches, and
## the worker until it runs once (`--version`). An installed worker is used only while its folders and file are the
## user's and no one else can write them, and the file is not a link.

import Archive from "std/archive"
import HTTP from "std/http"

MONTY_VERSION = "1.6.0"
MEMBER = "pydantic_monty_runtime-1.6.0.data/scripts/monty"
MAX_WHEEL_BYTES = 67_108_864
DOWNLOAD_MS = 300_000
## A download or staging folder older than this is left from a cancelled install.
STALE_S = 900
SMOKE_MS = 10_000
## The write bits of the group and of others; with read and run too, `OPEN_BITS`.
WRITE_BITS = 18
OPEN_BITS = 63
FILES = "https://files.pythonhosted.org/packages"
CHMOD = "/bin/chmod"
## Runs the worker with an empty environment: it needs none, and the server's holds API keys.
ENV = "/usr/bin/env"

## Where a wheel is and the sha256 it must have.
struct Wheel
  url: String
  sha256: String
end

## The wheel of the platform `uname` names, as `os arch`.
def wheel(platform: String) -> Result[Wheel]
  case platform
    "linux x86_64" ->
      ok(
        Wheel(
          url: (
            "#{FILES}/31/b0/ffccc75e32638e35f251baf45bc05357e8fdf69ee07cf1e0c7469b857b7f/" +
            "pydantic_monty_runtime-1.6.0-py3-none-manylinux_2_28_x86_64.whl"
          ),
          sha256: "f0d7d9eacbd94c7be6912fc30fbd60283fe407e4428562fa535dbb3e6ae47461",
        ),
      )
    "linux aarch64" ->
      ok(
        Wheel(
          url: (
            "#{FILES}/83/30/6ef32977bcde87b84417e9a0e765f50064ed4cfd4ec3863f6efd224aef01/" +
            "pydantic_monty_runtime-1.6.0-py3-none-manylinux_2_28_aarch64.whl"
          ),
          sha256: "3b5ed9340a7c7a1d1e62ab4218f792fb7439d47f680551453cf7935207ec7abb",
        ),
      )
    "macos x86_64" ->
      ok(
        Wheel(
          url: (
            "#{FILES}/f3/03/fc521336c215cf7cd3e59b1631a3e2946993c75bb734eee5dacebda9b6ce/" +
            "pydantic_monty_runtime-1.6.0-py3-none-macosx_10_12_x86_64.whl"
          ),
          sha256: "a1a34bdb1fb9b9226786deb0d6b6015fdd60e5badd8da74bab76b3272c5fb22e",
        ),
      )
    "macos arm64" ->
      ok(
        Wheel(
          url: (
            "#{FILES}/0a/a6/a0a765dddefce0f9ee14ef22de4b721a7b20922d232663f466851892fb2d/" +
            "pydantic_monty_runtime-1.6.0-py3-none-macosx_11_0_arm64.whl"
          ),
          sha256: "a2a1b385236aef0ff4165490eabc1d2764bf2cb5389076e0b8be52aa438c14c8",
        ),
      )
    _ ->
      error("monty: no worker for #{platform}; set the path of a monty #{MONTY_VERSION} binary", kind: "monty.install")
  end
end

## `os arch` of this machine, as `wheel` takes it.
def platform() -> Result[String]
  process = try Process.spawn_captured("uname", ["-m"])
  waited = Process.wait(process, 5_000)
  output = Process.output(process, 5_000)
  Process.close(process)
  _ = try waited
  ok("#{System.os()} #{(try output).stdout.strip}")
end

## The worker under `cache_dir`, fetched from `wheel` when it is not there yet.
def binary(cache_dir: String, wheel: Wheel) -> Result[String]
  dir = try Path.join([cache_dir, "monty-#{MONTY_VERSION}"])
  try folders(cache_dir)
  owner = try user_id(cache_dir)
  try private_cache(cache_dir, owner)
  return installed(dir, owner) if File.lstat(dir).ok?

  clear_stale(cache_dir)
  tag = "#{System.pid()}-#{Random.int(0, 999_999_999)}"
  part = try Path.join([cache_dir, "monty-#{MONTY_VERSION}-#{tag}.whl"])
  staging = try Path.join([cache_dir, "monty-#{MONTY_VERSION}-#{tag}"])
  fetched = fetch(wheel, part, staging)
  _ = Path.remove(part)
  if not fetched.ok?
    _ = Path.remove(staging)
    return error(fetched.message, kind: "monty.install")
  end

  # Another server may have finished first: its folder is as good as this one.
  if not Path.rename(staging, dir).ok?
    _ = Path.remove(staging)
  end

  return installed(dir, owner) if File.lstat(dir).ok?

  error("monty: the worker was not installed in #{dir}", kind: "monty.install")
end

private

def fetch(wheel: Wheel, part: String, staging: String) -> Result[Void]
  client = try HTTP.client()
  options = HTTP.DownloadOptions(timeout_ms: some(DOWNLOAD_MS), max_total_bytes: some(MAX_WHEEL_BYTES))
  got = try HTTP.download(client, wheel.url, part, options)
  return error("monty: the download of the worker answered #{got.status}") if got.status != 200

  digest = OpenSSL.Digest.hexencode(try File.sha256(part))
  return error("monty: the wheel has sha256 #{digest}, not #{wheel.sha256}") if digest != wheel.sha256

  limits = Archive.Options(timeout_ms: DOWNLOAD_MS, max_output_bytes: MAX_WHEEL_BYTES)
  _ = try Archive.extract_zip(part, [MEMBER], staging, limits)
  worker = try Path.join([staging, MEMBER])
  # The folders the extract made follow the umask: only the user may write them.
  try chmod(["-R", "go-w", staging])
  try chmod(["700", worker])
  runs(worker)
end

# Agentica has no call that sets a mode: chmod by its full path, not from PATH.
def chmod(args: List[String]) -> Result[Void]
  process = try Process.spawn(CHMOD, args)
  code = try Process.wait(process, 5_000)
  return error("monty: chmod of the worker failed") if code != 0

  ok()
end

# The worker answers `--version`: one built for another libc (musl) or CPU does not.
def runs(worker: String) -> Result[Void]
  process = try Process.spawn_captured(ENV, ["-i", worker, "--version"])
  waited = Process.wait(process, SMOKE_MS)
  Process.close(process)
  case waited
    ok(0) -> ok()
    _ -> error("monty: code mode isn't available on this system: its worker does not run here")
  end
end

# The cache folder is the user's and only theirs.
def private_cache(cache_dir: String, owner: Int) -> Result[Void]
  info = try File.lstat(cache_dir)
  if info.kind != "directory" or info.user_id != owner
    return error("monty: the cache folder #{cache_dir} is not a folder of this user", kind: "monty.install")
  end

  return ok() if info.mode.bit_and(OPEN_BITS) == 0

  error("monty: the cache folder #{cache_dir} is open to others: chmod 700 it", kind: "monty.install")
end

# The installed worker, when each folder down to it and the file are the user's, not links, and no one else can write
# them: another user could swap it.
def installed(dir: String, owner: Int) -> Result[String]
  path = dir
  for part in [""] + MEMBER.split("/")
    if not part.empty?
      path = try Path.join([path, part])
    end

    info = try File.lstat(path)
    wanted = "directory"
    if part == "monty"
      wanted = "file"
    end

    if info.kind != wanted or info.user_id != owner or info.mode.bit_and(WRITE_BITS) != 0
      return error(
        "monty: the worker at #{path} is not safe to run (a link, another owner or writable by others): remove #{dir}",
        kind: "monty.install",
      )
    end
  end

  ok(path)
end

# The user's id: the owner of a private folder made just now.
def user_id(cache_dir: String) -> Result[Int]
  probe = try Path.join([cache_dir, ".id-#{System.pid()}-#{Random.int(0, 999_999_999)}"])
  try Dir.mkdir_private(probe)
  info = File.lstat(probe)
  _ = Path.remove(probe)
  ok((try info).user_id)
end

# Removes the download and staging folders an install left when it was cancelled; a running install's are newer.
def clear_stale(cache_dir: String) -> Void
  now_s = Time.now_ms / 1000
  names: List[String] = Dir.list(cache_dir).unwrap_or([])
  for name in names
    next if not name.start_with?("monty-#{MONTY_VERSION}-")

    path = Path.join([cache_dir, name]).unwrap_or("")
    case File.lstat(path)
      ok(info) if now_s - info.modified_seconds > STALE_S -> _ = Path.remove(path)
      _ -> nil
    end
  end
end

# Makes each missing folder of `path`, private to the user.
def folders(path: String) -> Result[Void]
  return ok() if File.stat(path).ok?

  parent = try Path.join([path, ".."])
  try folders(try Path.resolve(parent))
  case Dir.mkdir_private(path)
    ok(_) -> ok()
    error(_) if File.stat(path).ok? -> ok()
    error(e) -> error(e.message)
  end
end
