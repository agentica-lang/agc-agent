import Protocol from "../protocol"

def fixture(path: String) -> Result[JSON.Value]
  text = try File.read_text("tests/fixtures/#{path}")
  JSON.parse(text)
end

def error_kind[T](result: Result[T]) -> String
  case result
    ok(_) -> "ok"
    error(e) -> e.kind
  end
end

# The fixture decodes, and encodes back to the same JSON.
def decode_fixture[T](key: String, decode: Fn[String, Result[T]], encode: Fn[T, String]) -> Result[T]
  json = try JSON.get(try fixture("messages.json"), key)
  value = try decode.call(JSON.encode(json))
  try Test.eq(JSON.parse(encode.call(value)), ok(json))
  ok(value)
end

def test_events_round_trip() -> Result[Void]
  items = try JSON.list(try fixture("events.json"))
  try Test.eq(items.size, 13)
  kinds: List[String] = []
  for item in items
    name = try JSON.string(try JSON.get(item, "name"))
    data = JSON.encode(try JSON.get(item, "data"))
    event = try Protocol.decode_event(name, data)
    try Test.eq(Protocol.event_name(event), name)
    try Test.eq(JSON.parse(Protocol.encode_event(event)), JSON.parse(data))
    try Test.eq(Protocol.decode_event(name, Protocol.encode_event(event)), ok(event))
    kinds = kinds.push(Protocol.kind_name(Protocol.kind(event)))
  end

  try Test.eq(kinds.uniq.size, 11)
  ok()
end

def test_requests_round_trip() -> Result[Void]
  new_session = try decode_fixture("new_session", &Protocol.decode_new_session, &Protocol.encode_new_session)
  try Test.eq(new_session, Protocol.NewSession(cwd: "/home/ana/project", model: some("qwen2.5-0.5b")))
  try Test.eq(Protocol.decode_new_session(Protocol.encode_new_session(new_session)), ok(new_session))

  no_model = try decode_fixture(
    "new_session_default_model",
    &Protocol.decode_new_session,
    &Protocol.encode_new_session,
  )

  try Test.eq(no_model.model, none)
  try Test.eq(Protocol.decode_new_session("{\"cwd\": \"/x\"}"), ok(Protocol.NewSession(cwd: "/x", model: none)))

  message = try decode_fixture("send_message", &Protocol.decode_send_message, &Protocol.encode_send_message)
  try Test.eq(Protocol.decode_send_message(Protocol.encode_send_message(message)), ok(message))

  approve = try decode_fixture("approve", &Protocol.decode_approve, &Protocol.encode_approve)
  try Test.eq(approve, Protocol.Approve(decision: Protocol.Decision.Allow))
  Test.eq(Protocol.decode_approve(Protocol.encode_approve(approve)), ok(approve))
end

def test_replies_round_trip() -> Result[Void]
  health = try decode_fixture("health", &Protocol.decode_health, &Protocol.encode_health)
  try Test.eq(Protocol.decode_health(Protocol.encode_health(health)), ok(health))

  created = try decode_fixture("session_created", &Protocol.decode_session_created, &Protocol.encode_session_created)
  try Test.eq(Protocol.decode_session_created(Protocol.encode_session_created(created)), ok(created))

  accepted = try decode_fixture(
    "message_accepted",
    &Protocol.decode_message_accepted,
    &Protocol.encode_message_accepted,
  )

  try Test.eq(Protocol.decode_message_accepted(Protocol.encode_message_accepted(accepted)), ok(accepted))

  list = try decode_fixture("session_list", &Protocol.decode_session_list, &Protocol.encode_session_list)
  try Test.eq(list.sessions.size, 1)
  try Test.eq(Protocol.decode_session_list(Protocol.encode_session_list(list)), ok(list))

  session = try decode_fixture("session", &Protocol.decode_session, &Protocol.encode_session)
  try Test.eq(session.last_event_id, 42)
  try Test.eq(session.history[1].role, Protocol.Role.Assistant)
  try Test.eq(Protocol.decode_session(Protocol.encode_session(session)), ok(session))

  failure = try decode_fixture("failure", &Protocol.decode_failure, &Protocol.encode_failure)
  Test.eq(Protocol.decode_failure(Protocol.encode_failure(failure)), ok(failure))
end

def test_invalid_input_is_a_typed_error() -> Result[Void]
  try Test.eq(error_kind(Protocol.decode_event("text_delta", "{}")), "protocol.invalid")
  try Test.eq(error_kind(Protocol.decode_event("usage", "{\"input\": \"1\"}")), "protocol.invalid")
  try Test.eq(error_kind(Protocol.decode_event("resync", "[]")), "protocol.invalid")
  try Test.eq(error_kind(Protocol.decode_send_message("not json")), "protocol.invalid")
  try Test.eq(error_kind(Protocol.decode_event("typing", "{}")), "protocol.unknown")
  try Test.eq(error_kind(Protocol.decode_approve("{\"decision\": \"maybe\"}")), "protocol.unknown")
  resolved = Protocol.decode_event("approval_resolved", "{\"approval_id\": \"a\", \"decision\": \"\"}")
  try Test.eq(error_kind(resolved), "protocol.unknown")
  history = "[{\"role\": \"tool\", \"text\": \"\"}]"
  session = "{\"id\": \"s\", \"cwd\": \"/\", \"model\": \"m\", \"last_event_id\": 0, \"history\": #{history}}"
  Test.eq(error_kind(Protocol.decode_session(session)), "protocol.unknown")
end

def test_event_ids() -> Result[Void]
  try Test.eq(Protocol.parse_event_id("0"), ok(0))
  try Test.eq(Protocol.parse_event_id(Protocol.format_event_id(1234)), ok(1234))
  for text in ["", "-1", "01", "1.5", "x", " 1", "9223372036854775808"]
    try Test.eq(error_kind(Protocol.parse_event_id(text)), "protocol.invalid")
  end

  ok()
end
