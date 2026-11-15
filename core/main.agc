import Cli from "src/cli"

def main() -> Void
  case Cli.parse(System.args())
    ok(command) -> puts(Cli.output(command))
    error(e) ->
      IO.warn(e.message)
      IO.warn(Cli.USAGE)
      System.exit(2)
  end
end
