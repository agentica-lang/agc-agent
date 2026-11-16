## The pinned worker binary: `scripts/monty` of the pydantic-monty-runtime wheel of this platform, downloaded on first
## use with its sha256 checked, and only that one member extracted. The wheel is untrusted until its hash matches.

import Archive from "std/archive"
import HTTP from "std/http"

MONTY_VERSION = "1.6.0"
MEMBER = "pydantic_monty_runtime-1.6.0.data/scripts/monty"
MAX_WHEEL_BYTES = 67_108_864
DOWNLOAD_MS = 300_000
FILES = "https://files.pythonhosted.org/packages"

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
  path = try Path.join([dir, MEMBER])
  return ok(path) if File.stat(path).ok?

  try folders(cache_dir)
  mode = (try File.stat(cache_dir)).mode
  if mode.bit_and(63) != 0
    return error("monty: the cache folder #{cache_dir} is open to others: chmod 700 it", kind: "monty.install")
  end

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

  return ok(path) if File.stat(path).ok?

  error("monty: the worker was not installed in #{dir}", kind: "monty.install")
end

private

def fetch(wheel: Wheel, part: String, staging: String) -> Result[Void]
  client = try HTTP.client()
  options = HTTP.DownloadOptions(timeout_ms: DOWNLOAD_MS, max_total_bytes: MAX_WHEEL_BYTES)
  got = try HTTP.download(client, wheel.url, part, options)
  return error("monty: the download of the worker answered #{got.status}") if got.status != 200

  digest = OpenSSL.Digest.hexencode(try File.sha256(part))
  return error("monty: the wheel has sha256 #{digest}, not #{wheel.sha256}") if digest != wheel.sha256

  limits = Archive.Options(timeout_ms: DOWNLOAD_MS, max_output_bytes: MAX_WHEEL_BYTES)
  _ = try Archive.extract_zip(part, [MEMBER], staging, limits)
  chmod = try Process.spawn("chmod", ["700", try Path.join([staging, MEMBER])])
  code = try Process.wait(chmod, 5_000)
  return error("monty: chmod of the worker failed") if code != 0

  ok()
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
