## The keys a login stores, in `auth.json` of the user's config folder (`$XDG_CONFIG_HOME/finn/`, else
## `~/.config/finn/`): `{"keys": {"PROVIDER": "KEY"}}`. Only its user may read it: a file that its group or others may
## read, or that another user owns, is not read (as ssh does with a private key), and the server says why.

FILE = "auth.json"

## The keys of the file by provider. `found` when the file is there, read or not; `refused` says why it was not read.
struct Stored
  keys: Map[String, String] = {}
  found: Bool = false
  refused: String = ""
end

## Where the file is; none without a home folder.
def path(read: Fn[String, Result[String]]) -> Optional[String]
  case read.call("XDG_CONFIG_HOME")
    ok(base) if not base.empty? -> some("#{base}/finn/#{FILE}")
    _ ->
      case read.call("HOME")
        ok(home) if not home.empty? -> some("#{home}/.config/finn/#{FILE}")
        _ -> none
      end
  end
end

## The user id of this process: the owner of `/proc/self` (Linux), else of the home folder; none when neither says.
def owner(read: Fn[String, Result[String]]) -> Optional[Int]
  case File.stat("/proc/self")
    ok(info) -> return some(info.user_id)
    error(_) -> nil
  end

  case File.stat(read.call("HOME").unwrap_or(""))
    ok(info) -> some(info.user_id)
    error(_) -> none
  end
end

## The keys of the file at `path`, none when it is missing; `owner` is the user who may own it.
def load(path: String, owner: Optional[Int]) -> Stored
  stat = File.stat(path)
  return Stored() if not stat.ok?

  info = stat.unwrap!

  if info.mode % 64 != 0
    return Stored(found: true, refused: "#{path} may be read by others: its keys are not used (chmod 600 #{path})")
  end

  if (owner.map { |id| id != info.user_id } == some(true))
    return Stored(found: true, refused: "#{path} belongs to another user: its keys are not used")
  end

  # A JSON error may quote the file: only its place is said.
  case decoded(path)
    ok(file) -> Stored(keys: file.keys.unwrap_or({}), found: true)
    error(_) -> Stored(found: true, refused: "#{path} is not a JSON object of keys: its keys are not used")
  end
end

## Writes `keys` to `path`, readable only by its user from the start. A new file is made private under another name in
## the same folder, then renamed; an existing one is replaced in one step and keeps its mode (0600, or it was refused).
def save(path: String, keys: Map[String, String]) -> Result[Void]
  text = JSON.encode(JSON.object({"keys": JSON.from(keys)}))
  return File.replace(path, text.bytes) if File.stat(path).ok?

  parts = path.split("/")
  dir = parts.take(parts.size - 1).join("/")
  try Dir.mkdir(dir)
  temp = "#{dir}/.#{FILE}.#{OpenSSL.Random.hex(8)}.tmp"
  moved = written(temp, path, text)
  if not moved.ok?
    _ = Path.remove(temp)
  end

  moved
end

private

struct AuthFile
  keys: Optional[Map[String, String]] = none
end

def decoded(path: String) -> Result[AuthFile] = JSON.decode(try File.read_text(path), AuthFile)

def written(temp: String, path: String, text: String) -> Result[Void]
  try File.open(temp, "create_private") do |handle| File.write(handle, text) end
  Path.rename(temp, path)
end
