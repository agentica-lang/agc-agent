import App from "src/app"
import Args from "src/args"

def main() -> Void
  case Args.parse(System.args())
    ok(command) -> dispatch(command)
    error(e) ->
      IO.warn(e.message)
      System.exit(2)
  end
end

private

def dispatch(command: Args.Command) -> Void
  case command
    Args.Command.Version -> puts("Finn Agent cli #{Args.VERSION}")
    Args.Command.Help(text) -> puts(text)
    Args.Command.Run(options) -> finish(App.run(options))
    Args.Command.Delete(options, id) -> finish(App.delete(options, id))
  end
end

def finish(result: Result[Int]) -> Void
  case result
    ok(code) ->
      IO.flush()
      System.exit(code)
    error(e) ->
      IO.warn("finn: #{e.message}")
      System.exit(1)
  end
end
