import Args from "args"
import Chat from "chat"
import Render from "render"
import Server from "server"

## Connects to the server of the state folder (starting it when none runs) and runs one session. Gives the exit code.
def run(options: Args.Options) -> Result[Int]
  dir = try Server.state_dir(options)
  server = try Server.connect(options, dir)
  Chat.run(server, options, Render.Style(thinking: options.thinking, color: not no_color?()))
end

private

def no_color?() -> Bool
  case System.env("NO_COLOR")
    ok(value) -> value != ""
    error(_) -> false
  end
end
