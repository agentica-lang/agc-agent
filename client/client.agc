## What every client of the server needs: finding or starting the server of the state folder, the HTTP calls of the
## protocol, and the task that reads the event stream of a session.

import Discovery from "src/discovery"
import Events from "src/feed"
import Http from "src/http"

VERSION = "0.0.1"

export Http.Server
export Http.KIND_UNREACHABLE
export Http.KIND_TIMEOUT
export Http.health
export Http.create_session
export Http.session
export Http.send_message
export Http.approve
export Http.delete_session
export Http.stop
export Http.open_events

export Discovery.Launch
export Discovery.KIND_STATE
export Discovery.KIND_SERVER
export Discovery.state_dir
export Discovery.connect

export Events.Feed
export Events.Item
export Events.start
