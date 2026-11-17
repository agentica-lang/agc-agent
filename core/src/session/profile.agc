## A session's profile on its setup: the tools its model sees, the text after its system prompt, what clients see of
## it. A profile that does not load shows no tool and refuses turns, also after a provider switch.

import Protocol from "pkg/protocol/protocol"
import Extensions from "../config/registry"
import Profiles from "../config/profiles"
import Session from "state"
import Tools from "../tools/tools"

## `setup` with the profile `name` of `loaded`.
def applied(setup: Session.Setup, loaded: Profiles.Loaded, name: String) -> Session.Setup
  case Profiles.find(loaded, name)
    ok(found) ->
      seen = Protocol.Profile(
        name: found.name,
        source: found.source,
        description: found.description,
        warnings: Profiles.warnings_of(loaded, found, known_tools()),
      )

      setup.with(
        system: Profiles.system(setup.base_system, found),
        shows: some(shows_of(ok(found))),
        profile: some(seen),
        profile_refused: "",
      )
    error(e) ->
      setup.with(
        system: setup.base_system,
        shows: some(shows_of(error(e.message))),
        profile: some(Protocol.Profile(name: name, source: "", warnings: [e.message])),
        profile_refused: e.message,
      )
  end
end

## Which tools a profile shows: none when it does not load.
def shows_of(profile: Result[Profiles.Profile]) -> Fn[String, Bool]
  case profile
    ok(found) -> ->(tool: String) { Profiles.exposes?(found, tool) }
    error(_) -> ->(_tool: String) { false }
  end
end

def known_tools() -> List[String] = Tools.all().map { |tool| tool.name } + Extensions.RESERVED
