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

def cause_kind[T](result: Result[T]) -> String
  case result
    ok(_) -> "ok"
    error(e) ->
      case e.cause
        some(cause) -> cause.kind
        none -> "no cause"
      end
  end
end

def session_json(last_event_id: Int, history: String) -> String
  head = "{\"id\": \"s\", \"cwd\": \"/\", \"model\": \"m\", \"pending_approvals\": []"
  "#{head}, \"last_event_id\": #{last_event_id}, \"history\": #{history}}"
end

# The fixture decodes, and encodes back to the same JSON.
def decode_fixture[T](key: String, decode: Fn[String, Result[T]], encode: Fn[T, String]) -> Result[T]
  json = try JSON.get(try fixture("messages.json"), key)
  value = try decode.call(JSON.encode(json))
  try Test.eq(JSON.parse(encode.call(value)), ok(json))
  ok(value)
end

def test_events_round_trip_and_cover_every_variant() -> Result[Void]
  items = try JSON.list(try fixture("events.json"))
  names: List[String] = []
  decisions: List[Protocol.Decision] = []
  sources: List[Protocol.ApprovalSource] = []
  reasons: List[Protocol.StopReason] = []
  for item in items
    name = try JSON.string(try JSON.get(item, "name"))
    data = JSON.encode(try JSON.get(item, "data"))
    event = try Protocol.decode_event(name, data)
    try Test.eq(Protocol.event_name(event), name)
    try Test.eq(JSON.parse(Protocol.encode_event(event)), JSON.parse(data))
    try Test.eq(Protocol.decode_event(name, Protocol.encode_event(event)), ok(event))
    names = names.push(name)
    case event
      Protocol.Event.ApprovalResolved(resolved) ->
        decisions = decisions.push(resolved.decision)
        sources = sources.push(resolved.source)
      Protocol.Event.TurnFinished(finished) -> reasons = reasons.push(finished.stop_reason)
      _ -> nil
    end
  end

  # Every list below comes from the enums, so a variant added to one needs a fixture and a name.
  kinds = Protocol.event_kinds()
  try Test.eq(kinds.map { |kind| Protocol.kind_name(kind) }.uniq.size, kinds.size)
  for kind in kinds
    try Test.eq(Protocol.parse_kind(Protocol.kind_name(kind)), ok(kind))
    try Test.assert(names.include?(Protocol.kind_name(kind)), "no fixture of #{Protocol.kind_name(kind)}")
  end

  for decision in Protocol.decisions()
    try Test.eq(Protocol.parse_decision(Protocol.decision_name(decision)), ok(decision))
    try Test.assert(decisions.include?(decision), "no fixture of decision #{Protocol.decision_name(decision)}")
  end

  for source in Protocol.approval_sources()
    try Test.eq(Protocol.parse_source(Protocol.source_name(source)), ok(source))
    try Test.assert(sources.include?(source), "no fixture of source #{Protocol.source_name(source)}")
  end

  for reason in Protocol.known_stop_reasons()
    try Test.eq(Protocol.parse_stop_reason(Protocol.stop_reason_name(reason)), reason)
    try Test.assert(reasons.include?(reason), "no fixture of stop reason #{Protocol.stop_reason_name(reason)}")
  end

  try Test.assert(reasons.include?(Protocol.StopReason.Other("pause_turn")), "no fixture of an unknown stop reason")
  ok()
end

def test_requests_round_trip() -> Result[Void]
  new_session = try decode_fixture("new_session", &Protocol.decode_new_session, &Protocol.encode_new_session)
  expected = Protocol.NewSession(cwd: "/home/ana/project", model: some("qwen2.5-0.5b"), api: some("openai_responses"))
  try Test.eq(new_session, expected)
  try Test.eq(Protocol.decode_new_session(Protocol.encode_new_session(new_session)), ok(new_session))

  no_model = try decode_fixture(
    "new_session_default_model",
    &Protocol.decode_new_session,
    &Protocol.encode_new_session,
  )

  try Test.eq([no_model.model, no_model.api], [none, none])
  try Test.eq(error_kind(Protocol.decode_new_session("{\"cwd\": \"/x\", \"api\": \"\"}")), "protocol.invalid")
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

  info = try decode_fixture("server_info", &Protocol.decode_server_info, &Protocol.encode_server_info)
  try Test.eq(Protocol.decode_server_info(Protocol.encode_server_info(info)), ok(info))

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

  failure = try decode_fixture("failure", &Protocol.decode_failure, &Protocol.encode_failure)
  try Test.eq(failure.kind, Protocol.KIND_APPROVAL_RESOLVED)
  Test.eq(Protocol.decode_failure(Protocol.encode_failure(failure)), ok(failure))
end

def test_sessions_round_trip_idle_and_mid_turn() -> Result[Void]
  idle = try decode_fixture("session", &Protocol.decode_session, &Protocol.encode_session)
  try Test.eq(idle.turn_id, none)
  try Test.eq(idle.turn_from_event_id, none)
  try Test.eq(idle.pending_approvals.size, 0)
  try Test.eq(Protocol.decode_session(Protocol.encode_session(idle)), ok(idle))

  running = try decode_fixture("session_mid_turn", &Protocol.decode_session, &Protocol.encode_session)
  try Test.eq(running.turn_id, some("t2"))
  try Test.eq(running.turn_from_event_id, some(50))
  try Test.assert(
    running.turn_from_event_id.unwrap_or(0) <= running.last_event_id,
    "turn starts before the last event",
  )

  try Test.eq(running.pending_approvals[0].tool, "bash")
  try Test.eq(Protocol.decode_session(Protocol.encode_session(running)), ok(running))

  roles = (idle.history + running.history).map { |message| message.role }
  for role in Protocol.roles()
    try Test.eq(Protocol.parse_role(Protocol.role_name(role)), ok(role))
    try Test.assert(roles.include?(role), "no fixture of role #{Protocol.role_name(role)}")
  end

  ok()
end

def test_invalid_input_is_a_typed_error() -> Result[Void]
  try Test.eq(error_kind(Protocol.decode_event("text_delta", "{}")), "protocol.invalid")
  try Test.eq(error_kind(Protocol.decode_event("usage", "{\"input\": \"1\"}")), "protocol.invalid")
  try Test.eq(error_kind(Protocol.decode_event("resync", "[]")), "protocol.invalid")
  try Test.eq(error_kind(Protocol.decode_send_message("not json")), "protocol.invalid")
  try Test.eq(error_kind(Protocol.decode_event("typing", "{}")), "protocol.unknown")
  try Test.eq(error_kind(Protocol.decode_approve("{\"decision\": \"maybe\"}")), "protocol.unknown")
  resolved = "{\"approval_id\": \"a\", \"decision\": \"allow\", \"source\": \"magic\"}"
  try Test.eq(error_kind(Protocol.decode_event("approval_resolved", resolved)), "protocol.unknown")
  no_source = "{\"approval_id\": \"a\", \"decision\": \"allow\"}"
  try Test.eq(error_kind(Protocol.decode_event("approval_resolved", no_source)), "protocol.invalid")
  history = "[{\"role\": \"tool\", \"text\": \"\"}]"
  session = session_json(0, history)

  try Test.eq(error_kind(Protocol.decode_session(session)), "protocol.unknown")

  # The JSON error stays as the cause.
  try Test.eq(cause_kind(Protocol.decode_event("text_delta", "{}")), "json.decode")
  Test.eq(cause_kind(Protocol.decode_send_message("not json")), "json.parse")
end

def test_requests_refuse_unknown_keys_and_empty_strings_but_events_and_replies_do_not() -> Result[Void]
  try Test.eq(error_kind(Protocol.decode_new_session("{\"cwd\": \"/x\", \"modle\": \"m\"}")), "protocol.invalid")
  try Test.eq(error_kind(Protocol.decode_send_message("{\"text\": \"hi\", \"x\": 1}")), "protocol.invalid")
  try Test.eq(error_kind(Protocol.decode_approve("{\"decision\": \"allow\", \"scope\": \"all\"}")), "protocol.invalid")
  try Test.eq(error_kind(Protocol.decode_send_message("[]")), "protocol.invalid")
  try Test.eq(error_kind(Protocol.decode_new_session("{\"cwd\": \"\"}")), "protocol.invalid")
  try Test.eq(error_kind(Protocol.decode_new_session("{\"cwd\": \"/x\", \"model\": \"\"}")), "protocol.invalid")
  try Test.eq(error_kind(Protocol.decode_send_message("{\"text\": \"\"}")), "protocol.invalid")

  try Test.eq(
    Protocol.decode_event("text_delta", "{\"text\": \"a\", \"later\": 1}"),
    ok(Protocol.Event.TextDelta(Protocol.TextDelta(text: "a"))),
  )

  try Test.eq(Protocol.decode_health("{\"version\": \"1\", \"later\": 1}"), ok(Protocol.Health(version: "1")))
  Test.eq(Protocol.decode_event("resync", "{\"later\": 1}"), ok(Protocol.Event.Resync))
end

def test_negative_numbers_are_refused() -> Result[Void]
  usage = "{\"input\": 1, \"output\": 1, \"cache_read\": 1, \"cache_write\": 1, \"context\": -1}"
  try Test.eq(error_kind(Protocol.decode_event("usage", usage)), "protocol.invalid")
  finished = "{\"call_id\": \"c\", \"ok\": true, \"summary\": \"\", \"duration_ms\": -5}"
  try Test.eq(error_kind(Protocol.decode_event("tool_finished", finished)), "protocol.invalid")
  started = "{\"turn_id\": \"t\", \"history_size\": -1}"
  try Test.eq(error_kind(Protocol.decode_event("turn_started", started)), "protocol.invalid")
  session = session_json(-1, "[]")

  try Test.eq(error_kind(Protocol.decode_session(session)), "protocol.invalid")
  from = "{\"id\": \"s\", \"cwd\": \"/\", \"model\": \"m\", \"last_event_id\": 1, \"turn_from_event_id\": -1"
  Test.eq(
    error_kind(Protocol.decode_session("#{from}, \"pending_approvals\": [], \"history\": []}")),
    "protocol.invalid",
  )
end

def test_session_turn_fields_agree() -> Result[Void]
  base = "{\"id\": \"s\", \"cwd\": \"/\", \"model\": \"m\", \"pending_approvals\": [], \"history\": []"
  late = "#{base}, \"last_event_id\": 5, \"turn_id\": \"t\", \"turn_from_event_id\": 9}"
  try Test.eq(error_kind(Protocol.decode_session(late)), "protocol.invalid")
  only_id = "#{base}, \"last_event_id\": 5, \"turn_id\": \"t\"}"
  try Test.eq(error_kind(Protocol.decode_session(only_id)), "protocol.invalid")
  only_from = "#{base}, \"last_event_id\": 5, \"turn_from_event_id\": 2}"
  try Test.eq(error_kind(Protocol.decode_session(only_from)), "protocol.invalid")
  edge = "#{base}, \"last_event_id\": 5, \"turn_id\": \"t\", \"turn_from_event_id\": 5}"
  Test.assert(Protocol.decode_session(edge).ok?, "a turn that starts at the last event is valid")
end

def test_other_stop_reason_is_never_a_known_name() -> Result[Void]
  try Test.eq(Protocol.parse_stop_reason("end_turn"), Protocol.StopReason.EndTurn)
  known = Protocol.Event.TurnFinished(
    Protocol.TurnFinished(turn_id: "t", stop_reason: Protocol.StopReason.Other("end_turn")),
  )

  expected = Protocol.Event.TurnFinished(Protocol.TurnFinished(turn_id: "t", stop_reason: Protocol.StopReason.EndTurn))
  Test.eq(Protocol.decode_event("turn_finished", Protocol.encode_event(known)), ok(expected))
end

def test_event_ids() -> Result[Void]
  try Test.eq(Protocol.parse_event_id("0"), ok(0))
  try Test.eq(Protocol.parse_event_id(Protocol.format_event_id(1234)), ok(1234))
  for text in ["", "-1", "01", "1.5", "x", " 1", "9223372036854775808"]
    try Test.eq(error_kind(Protocol.parse_event_id(text)), "protocol.invalid")
  end

  ok()
end

def test_routes() -> Result[Void]
  try Test.eq(Protocol.approval_path("s1", "a1"), "/v1/sessions/s1/approvals/a1")
  try Test.eq(Protocol.events_path("s1"), "/v1/sessions/s1/events")
  try Test.eq(Protocol.compact_path("s1"), "/v1/sessions/s1/compact")
  Test.eq(Protocol.stop_path("s1"), "/v1/sessions/s1/stop")
end

def test_session_settings_round_trip_and_refuse_unknown_levels() -> Result[Void]
  both = Protocol.UpdateSession(model: some("qwen3"), effort: some("high"))
  try Test.eq(Protocol.decode_update_session(Protocol.encode_update_session(both)), ok(both))
  try Test.eq(Protocol.decode_update_session("{\"effort\": \"low\"}"), ok(Protocol.UpdateSession(effort: some("low"))))
  try Test.eq(Protocol.decode_update_session("{}"), ok(Protocol.UpdateSession()))
  try Test.eq(error_kind(Protocol.decode_update_session("{\"effort\": \"max\"}")), "protocol.unknown")
  try Test.eq(error_kind(Protocol.decode_update_session("{\"model\": \"\"}")), "protocol.invalid")
  try Test.eq(error_kind(Protocol.decode_update_session("{\"modle\": \"m\"}")), "protocol.invalid")
  compacted = Protocol.Compacted(compacted: true)
  try Test.eq(Protocol.decode_compacted(Protocol.encode_compacted(compacted)), ok(compacted))
  idle = try decode_fixture("session", &Protocol.decode_session, &Protocol.encode_session)
  try Test.eq(idle.effort, none)
  thinking = idle.with(effort: some("medium"))
  Test.eq(Protocol.decode_session(Protocol.encode_session(thinking)), ok(thinking))
end
