## The private folders of the server (state, data, sessions): made with mode 0700 when missing, and checked.

import Sandbox from "../tools/sandbox"

## Makes `given` (and its parents) when it is missing; an error unless it is a folder of mode 0700 that this user owns.
def private_folder(given: String) -> Result[Void]
  path = try Path.resolve(given)
  if not File.stat(path).ok?
    try Dir.mkdir(Sandbox.parent(path))
    try Dir.mkdir_private(path)
  end

  info = try File.stat(path)
  return error("#{path} is not a folder") if info.kind != "directory"
  return error("#{path} must be private (mode 0700), it has mode #{info.mode}") if info.mode % 64 != 0

  for me in option_list(owner_id())
    return error("#{path} is not owned by you") if info.user_id != me
  end

  ok()
end

private

# The user id of this process, from the owner of its /proc entry or of the home folder; none where neither is there.
def owner_id() -> Optional[Int]
  for place in ["/proc/self", System.env("HOME").unwrap_or("")]
    case File.stat(place)
      ok(info) if place != "" -> return some(info.user_id)
      _ -> nil
    end
  end

  none
end

def option_list[T](value: Optional[T]) -> List[T]
  case value
    some(v) -> [v]
    none -> []
  end
end
