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
  expected = Protocol.NewSession(
    cwd: "/home/ana/project",
    model: some("qwen2.5-0.5b"),
    api: some("openai_responses"),
    provider: some("fireworks"),
    profile: some("plan"),
    remember: some(true),
  )

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
  try Test.eq(accepted.message_id, none)
  queued = try decode_fixture(
    "message_queued_accepted",
    &Protocol.decode_message_accepted,
    &Protocol.encode_message_accepted,
  )

  try Test.eq(queued, Protocol.MessageAccepted(turn_id: "t1", message_id: some("t1.1")))

  list = try decode_fixture("session_list", &Protocol.decode_session_list, &Protocol.encode_session_list)
  try Test.eq(list.sessions.map { |s| s.empty }, [false, true])
  try Test.eq(Protocol.decode_session_list(Protocol.encode_session_list(list)), ok(list))
  providers = try decode_fixture("provider_list", &Protocol.decode_provider_list, &Protocol.encode_provider_list)
  try Test.eq(providers.providers.map { |p| p.name }, ["local", "fireworks"])

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
  shown = idle.history.map { |m|
    [
      m.thinking.to_s,
      m.tool.map { |t| t.name }.unwrap_or(""),
      m.done.map { |d| d.summary }.unwrap_or(""),
      m.stop.map { |f| "#{Protocol.stop_reason_name(f.stop_reason)} #{f.max_tokens}" }.unwrap_or(""),
    ].join(" ")
  }

  try Test.eq(
    shown,
    ["false   ", "true   ", "false write_file wrote 1 line ", "false   max_tokens some(8192)", "false   "],
  )

  shell = idle.with(shell_id: some("shell-1"))
  try Test.eq(Protocol.decode_session(Protocol.encode_session(shell)), ok(shell))
  used = Protocol.Usage(
    input: 9,
    output: 4,
    cache_read: 7,
    cache_write: 1,
    context: 17,
    session_cost: some(0.5),
    window: some(100),
    call_output: some(2),
    output_ms: some(1500),
  )

  try Test.eq(
    Protocol.decode_session(Protocol.encode_session(idle.with(usage: some(used)))),
    ok(idle.with(usage: some(used))),
  )

  plain = used.with(session_cost: none, window: none, call_output: none, output_ms: none)
  try Test.eq(Protocol.encode_session(idle.with(usage: some(plain), history: [])).include?("null}"), false)
  try Test.eq(
    Protocol.decode_session(Protocol.encode_session(idle.with(usage: some(plain)))),
    ok(idle.with(usage: some(plain))),
  )

  event = Protocol.Event.Usage(used)
  try Test.eq(Protocol.decode_event("usage", Protocol.encode_event(event)), ok(event))

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
  try Test.eq(
    error_kind(Protocol.decode_event("todos", "{\"todos\": [{\"content\": \"x\", \"status\": \"done\"}]}")),
    "protocol.invalid",
  )

  bad_todo = session_json(0, "[]").replace(
    "\"history\"",
    "\"todos\": [{\"content\": \"x\", \"status\": \"done\"}], \"history\"",
  )

  try Test.eq(error_kind(Protocol.decode_session(bad_todo)), "protocol.invalid")

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
  timed = "{\"input\": 1, \"output\": 1, \"cache_read\": 1, \"cache_write\": 1, \"context\": 1, \"output_ms\": -1}"
  try Test.eq(error_kind(Protocol.decode_event("usage", timed)), "protocol.invalid")
  for cost in ["-0.5", "1e999"]
    costly = (
      "{\"input\": 1, \"output\": 1, \"cache_read\": 1, \"cache_write\": 1, \"context\": 1, \"session_cost\": #{cost}}"
    )

    try Test.eq([cost, error_kind(Protocol.decode_event("usage", costly))], [cost, "protocol.invalid"])
  end

  windowed = "{\"input\": 1, \"output\": 1, \"cache_read\": 1, \"cache_write\": 1, \"context\": 1, \"window\": -1}"
  try Test.eq(error_kind(Protocol.decode_event("usage", windowed)), "protocol.invalid")
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
  try Test.eq(Protocol.tree_path("s1"), "/v1/sessions/s1/tree")
  try Test.eq(Protocol.export_path("s1"), "/v1/sessions/s1/export")
  try Test.eq(Protocol.branch_path("s1"), "/v1/sessions/s1/branch")
  try Test.eq(Protocol.fork_path("s1"), "/v1/sessions/s1/fork")
  try Test.eq(Protocol.shell_path("s1"), "/v1/sessions/s1/shell")
  Test.eq(Protocol.stop_path("s1"), "/v1/sessions/s1/stop")
end

def test_the_tree_and_its_branches_round_trip() -> Result[Void]
  nodes = [
    Protocol.TreeNode(id: 1, text: "one", answer: "a", last: 6, active: true),
    Protocol.TreeNode(id: 7, parent: some(1), text: "two", last: 9),
  ]

  tree = Protocol.SessionTree(nodes: nodes)
  try Test.eq(Protocol.decode_session_tree(Protocol.encode_session_tree(tree)), ok(tree))
  entries = [
    Protocol.ExportEntry(kind: "user", text: "hi"),
    Protocol.ExportEntry(kind: "tool", text: "a.txt", tool: "read_file", ok: some(true)),
    Protocol.ExportEntry(kind: "tool", text: "ls", tool: "bash"),
  ]

  exported = Protocol.SessionExport(
    id: "s1",
    title: "hi",
    created_ms: 1000,
    entries: entries,
    todos: [Protocol.Todo(content: "one", status: "pending")],
  )

  try Test.eq(Protocol.decode_session_export(Protocol.encode_session_export(exported)), ok(exported))
  branched = Protocol.Branched(id: "s2-ab", text: "two")
  try Test.eq(Protocol.decode_branched(Protocol.encode_branched(branched)), ok(branched))
  branch = Protocol.Branch(entry: 7)
  try Test.eq(Protocol.decode_branch(Protocol.encode_branch(branch)), ok(branch))
  try Test.eq(Protocol.decode_fork(Protocol.encode_fork(Protocol.Fork())), ok(Protocol.Fork()))
  try Test.eq(Protocol.decode_fork("{\"entry\": 3}"), ok(Protocol.Fork(entry: some(3))))
  try Test.eq(error_kind(Protocol.decode_branch("{\"entry\": -1}")), "protocol.invalid")
  Test.eq(error_kind(Protocol.decode_fork("{\"entri\": 1}")), "protocol.invalid")
end

def test_the_server_status_and_its_stop_round_trip() -> Result[Void]
  status = Protocol.ServerStatus(
    pid: 42,
    version: "0.0.1",
    started_s: 1000,
    sessions: 3,
    running_turns: 1,
    stopping: true,
    approvals: some(false),
    clipboard: some(Protocol.ClipboardSetting(provider: "command", command: ["xclip", "-i"])),
    keys: some([Protocol.KeySetting(action: "logs", key: "f9")]),
  )

  try Test.eq(Protocol.decode_server_status(Protocol.encode_server_status(status)), ok(status))
  stop = Protocol.StopServer(now: some(true))
  try Test.eq(Protocol.decode_stop_server(Protocol.encode_stop_server(stop)), ok(stop))
  try Test.eq(Protocol.decode_stop_server("{}"), ok(Protocol.StopServer()))
  try Test.eq(error_kind(Protocol.decode_stop_server("{\"later\": true}")), "protocol.invalid")
  try Test.eq(Protocol.SERVER_PATH, "/v1/server")
  Test.eq(Protocol.SERVER_STOP_PATH, "/v1/server/stop")
end

def test_a_shell_command_round_trips() -> Result[Void]
  run = Protocol.RunShell(command: "ls", context: false)
  try Test.eq(Protocol.decode_run_shell(Protocol.encode_run_shell(run)), ok(run))
  try Test.eq(error_kind(Protocol.decode_run_shell("{\"command\": \"ls\"}")), "protocol.invalid")
  try Test.eq(error_kind(Protocol.decode_run_shell("{\"command\": \"\", \"context\": true}")), "protocol.invalid")
  accepted = Protocol.ShellAccepted(shell_id: "sh1")
  Test.eq(Protocol.decode_shell_accepted(Protocol.encode_shell_accepted(accepted)), ok(accepted))
end

# A stop names the turn it is for, or none: an empty body is the stop of an older client.
def test_a_stop_and_a_file_list_round_trip() -> Result[Void]
  stop = Protocol.StopTurn(turn_id: some("t1"))
  try Test.eq(Protocol.decode_stop_turn(Protocol.encode_stop_turn(stop)), ok(stop))
  try Test.eq(
    [Protocol.decode_stop_turn(""), Protocol.decode_stop_turn(Protocol.encode_stop_turn(Protocol.StopTurn()))],
    [ok(Protocol.StopTurn()), ok(Protocol.StopTurn())],
  )

  try Test.eq(error_kind(Protocol.decode_stop_turn("{\"turn_id\": \"\"}")), "protocol.invalid")
  stopped = Protocol.Stopped(stopped: true)
  try Test.eq(Protocol.decode_stopped(Protocol.encode_stopped(stopped)), ok(stopped))
  files = Protocol.FileList(files: ["a.txt", "src/b.agc"], truncated: true)
  try Test.eq(Protocol.decode_file_list(Protocol.encode_file_list(files)), ok(files))
  Test.eq(Protocol.files_path("s1"), "/v1/sessions/s1/files")
end

def test_a_login_round_trips() -> Result[Void]
  login = Protocol.Login(key: "sk-1")
  try Test.eq(Protocol.decode_login(Protocol.encode_login(login)), ok(login))
  try Test.eq(error_kind(Protocol.decode_login("{\"key\": \"\"}")), "protocol.invalid")
  url = Protocol.LoginUrl(base_url: "http://127.0.0.1:8080/v1")
  try Test.eq(Protocol.decode_login_url(Protocol.encode_login_url(url)), ok(url))
  try Test.eq(error_kind(Protocol.decode_login_url("{\"key\": \"sk\"}")), "protocol.invalid")
  local = Protocol.LoginStatus(
    name: "local",
    label: "",
    key_env: "",
    from: "",
    coming: false,
    asks: "url",
    base_url: "u",
  )

  try Test.eq(Protocol.decode_login_status(Protocol.encode_login_status(local)), ok(local))
  status = Protocol.LoginStatus(name: "groq", label: "", key_env: "GROQ_API_KEY", from: "stored", coming: false)
  list = Protocol.LoginList(providers: [status], first: false)
  try Test.eq(Protocol.decode_login_status(Protocol.encode_login_status(status)), ok(status))
  Test.eq(Protocol.decode_login_list(Protocol.encode_login_list(list)), ok(list))
end

def test_session_settings_round_trip_and_refuse_unknown_levels() -> Result[Void]
  both = Protocol.UpdateSession(provider: some("fireworks"), model: some("qwen3"), effort: some("high"))
  try Test.eq(Protocol.decode_update_session(Protocol.encode_update_session(both)), ok(both))
  try Test.eq(Protocol.decode_update_session("{\"effort\": \"low\"}"), ok(Protocol.UpdateSession(effort: some("low"))))
  try Test.eq(Protocol.decode_update_session("{}"), ok(Protocol.UpdateSession()))
  edits = Protocol.UpdateSession(accept_edits: some(true))
  try Test.eq(Protocol.decode_update_session(Protocol.encode_update_session(edits)), ok(edits))
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

# Every struct and enum of src/ and every error kind is in the wire shape, so a change to one changes the digest.
# `Event` is named by `EventKind`, whose names are its variants.
def test_the_wire_shape_has_every_record_enum_and_kind() -> Result[Void]
  shape = Protocol.wire_shape()
  found: List[String] = []
  files = (try Dir.list("src")).select { |f| f.end_with?(".agc") }
  for file in files
    for line in (try File.read_text("src/#{file}")).split("\n")
      words = line.split(" ")
      if words.size > 1 and (words[0] == "struct" or words[0] == "enum") and words[1] != "Event"
        found = found.push(words[1])
        try Test.assert(shape.any? { |s| s.start_with?("#{words[1]}{") or s.start_with?("#{words[1]}[") }, words[1])
      elsif words.size > 2 and words[0].start_with?("KIND_")
        found = found.push(words[0])
        try Test.assert(shape.include?(words[2].replace("\"", "")), words[0])
      end
    end
  end

  Test.assert(found.size > 40, "the scan found #{found.size} names")
end

# Every constant of routes.agc is in the wire shape, one path of a session for each `def *_path(session_id`, and the
# paths outside a session.
def test_the_wire_shape_has_every_path() -> Result[Void]
  shape = Protocol.wire_shape()
  defs = 0
  for line in (try File.read_text("src/routes.agc")).split("\n")
    words = line.split(" ")
    if words.size > 2 and words[1] == "=" and words[0] == words[0].upcase
      try Test.assert(shape.include?(words[2].replace("\"", "")), words[0])
    elsif words.size > 1 and words[0] == "def" and words[1].include?("_path(session_id")
      defs += 1
    end
  end

  try Test.assert(defs > 5, "the scan found #{defs} paths")
  try Test.assert(shape.include?(Protocol.auth_path("P")), "auth_path")
  Test.eq(shape.select { |s| s.start_with?("/v1/sessions/ID") }.size, defs)
end
