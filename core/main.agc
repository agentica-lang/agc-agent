import Cli from "src/config/cli"
import Core from "core"

def main() -> Void
  case Cli.parse(System.args())
    ok(Cli.Command.Serve) -> Core.serve(Core.registry())
    ok(command) -> puts(Cli.output(command))
    error(e) ->
      IO.warn(e.message)
      IO.warn(Cli.USAGE)
      System.exit(2)
  end
end
