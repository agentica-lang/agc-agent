## The fake worker of this package's tests: its one argument is the fixture.

import Monty from "../../monty"

def main() -> Void
  Monty.serve_fake(System.args()[0])
end
