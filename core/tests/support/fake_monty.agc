## The fake Monty worker of the monty package: its one argument is the fixture.

import Monty from "pkg/monty/monty"

def main() -> Void
  Monty.serve_fake(System.args()[0])
end
