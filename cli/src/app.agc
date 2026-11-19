import Client from "pkg/client/client"
import Args from "args"
import Chat from "chat"
import Render from "render"

## Connects to the server of the state folder (starting it when none runs) and runs one session. Gives the exit code.
def run(options: Args.Options) -> Result[Int]
  launch = Args.launch(options)
  dir = try Client.state_dir(launch)
  server = try Client.connect_or_restart(launch, dir, options.prompt.none?)
  for note in [Client.code_mode_note(server, options.code_mode), Client.version_note(server, dir)]
    if not note.empty?
      IO.warn(note)
    end
  end

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

## Writes the branch of a session to a Markdown file, on the server of the state folder (starting it when none runs).
def export_session(options: Args.Options, id: String, path: Optional[String], force: Bool) -> Result[Int]
  launch = Args.launch(options)
  server = try Client.connect(launch, try Client.state_dir(launch))
  file = try Client.saved(try Client.exported(server, id), Client.export_path(id, path), force)
  puts("[session #{id} exported to #{Client.printable(file)}]")
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
