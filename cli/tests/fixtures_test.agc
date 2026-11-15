# The recorded fixtures stay in the shape of the protocol: a renamed field makes them fail here.

import Protocol from "pkg/protocol/protocol"
import Fixtures from "support/fixtures"

def test_every_session_fixture_decodes_and_encodes_back_to_itself() -> Result[Void]
  names = try Fixtures.names("session_", ".json")
  try Test.assert(names.size >= 4, "the session fixtures are found: #{names}")
  for name in names
    session = try Fixtures.session(name)
    try Test.eq(Protocol.decode_session(Protocol.encode_session(session)), ok(session))
  end

  ok()
end

def test_every_event_of_every_stream_fixture_decodes_and_encodes_back_to_itself() -> Result[Void]
  names = try Fixtures.names("", ".sse")
  try Test.assert(names.size >= 10, "the stream fixtures are found: #{names}")
  for name in names
    for event in try Fixtures.events(name)
      encoded = Protocol.decode_event(Protocol.event_name(event), Protocol.encode_event(event))
      try Test.eq(encoded, ok(event))
    end
  end

  ok()
end
