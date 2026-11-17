## Finn's server with the example extension: run it as `finn serve` would be run.

import Core from "pkg/core/core"
import Extension from "extension"

def main() -> Void
  Core.serve(Extension.register(Core.registry()))
end
