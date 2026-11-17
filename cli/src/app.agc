import Client from "pkg/client/client"
import Args from "args"
import Chat from "chat"
import Render from "render"

## Connects to the server of the state folder (starting it when none runs) and runs one session. Gives the exit code.
def run(options: Args.Options) -> Result[Int]
  launch = Args.launch(options)
  server = try Client.connect(launch, try Client.state_dir(launch))
  Chat.run(server, options, Render.Style(thinking: options.thinking, color: not no_color?()))
end

## Deletes a session on the server of the state folder (starting it when none runs). Gives the exit code.
def delete(options: Args.Options, id: String) -> Result[Int]
  launch = Args.launch(options)
  server = try Client.connect(launch, try Client.state_dir(launch))
  try Client.delete_session(server, id)
  puts("[session #{id} deleted]")
  ok(0)
end

def logout(options: Args.Options, name: Optional[String]) -> Result[Int]
  launch = Args.launch(options)
  server = try Client.connect(launch, try Client.state_dir(launch))
  try Client.logout(server, name)
  puts("[#{Client.logged_out(name)}]")
  ok(0)
end

private

def no_color?() -> Bool
  case System.env("NO_COLOR")
    ok(value) -> value != ""
    error(_) -> false
  end
end
