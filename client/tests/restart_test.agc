# What a client does about a server of another version: asks on a terminal, never without one, and `--restart` answers.

import Client from "../client"

OLDER = "20260101000000"

struct Ran
  wanted: Bool
  questions: List[String]
end

def test_on_a_terminal_yes_restarts_and_no_does_not() -> Result[Void]
  yes = try ran(["y"], some(0))
  try Test.eq(yes.wanted, true)
  try Test.eq(yes.questions.size, 1)
  try Test.assert(yes.questions[0].include?("Restart it and go on? It keeps the sessions. [Y/n]"), yes.questions[0])
  try Test.assert(yes.questions[0].include?("(pid 11) runs an older Finn (#{OLDER})"), yes.questions[0])
  try Test.eq((try ran([""], some(0))).wanted, true)
  try Test.eq((try ran(["n"], some(0))).wanted, false)
  Test.eq((try ran([], some(0))).wanted, false)
end

def test_running_turns_are_named_and_the_default_is_no() -> Result[Void]
  turns = try ran([""], some(2))
  try Test.eq(turns.wanted, false)
  try Test.assert(
    turns.questions[0].include?("It stops 2 running turns and keeps the sessions. [y/N]"),
    turns.questions[0],
  )

  agreed = try ran(["yes"], some(1))
  try Test.eq(agreed.wanted, true)
  try Test.assert(agreed.questions[0].include?("It stops 1 running turn and"), agreed.questions[0])
  unknown = try ran([""], none)
  try Test.eq(unknown.wanted, false)
  Test.assert(unknown.questions[0].include?("[y/N]"), unknown.questions[0])
end

def test_an_answer_that_is_neither_is_asked_again_and_a_newer_server_is_named() -> Result[Void]
  again = try ran(["maybe", "y"], some(0), "30000101000000")
  try Test.eq(again.wanted, true)
  try Test.eq(again.questions.size, 2)
  Test.assert(again.questions[0].include?("runs a newer Finn (30000101000000)"), again.questions[0])
end

def test_without_a_terminal_nothing_is_asked_and_restart_answers_yes() -> Result[Void]
  quiet = try ran(["y"], some(0), OLDER, false, false)
  try Test.eq(quiet.wanted, false)
  try Test.eq(quiet.questions.size, 0)
  flag = try ran(["n"], some(3), OLDER, false, true)
  try Test.eq(flag.wanted, true)
  Test.eq(flag.questions.size, 0)
end

def ran(
  answers: List[String],
  turns: Optional[Int],
  version: String = OLDER,
  terminal: Bool = true,
  restart: Bool = false,
) -> Result[Ran]
  seen: Channel[String] = Channel.new(8)
  left: Channel[String] = Channel.new(8)
  for answer in answers
    _ = left.send(answer, 0)
  end

  asking = Client.Asking(
    terminal: terminal,
    restart: restart,
    ask: ->(text: String) {
      _ = seen.send(text, 0)
      case left.recv(0)
        ok(line) -> some(line)
        error(_) -> none
      end
    },
  )

  wanted = try Client.restart_wanted(asking, 11, version, turns, "20261118000000")
  questions: List[String] = []
  while true
    case seen.recv(0)
      ok(text) -> questions = questions.push(text)
      error(_) -> break
    end
  end

  ok(Ran(wanted: wanted, questions: questions))
end
