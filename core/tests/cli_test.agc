import LLM from "pkg/llm/llm"
import Cli from "../src/cli"
import Config from "../src/config"

def test_version_names_core_and_llm() -> Result[Void]
  try Test.eq(Cli.parse(["--version"]), ok(Cli.Command.Version))
  Test.eq(Cli.output(Cli.Command.Version), "agc-agent core #{Cli.VERSION} (llm #{LLM.VERSION})")
end

def test_no_arguments_shows_help() -> Result[Void]
  try Test.eq(Cli.parse([]), ok(Cli.Command.Help))
  Test.eq(Cli.parse(["-h"]), ok(Cli.Command.Help))
end

def test_unknown_arguments_fail() -> Result[Void] = Test.error?(Cli.parse(["--nope"]))

def test_the_context_window_must_be_a_positive_number() -> Result[Void]
  for bad in ["0", "-5", "lots"]
    try Test.error?(Config.from_env(->(name) { env(name, bad) }))
  end

  options = try Config.from_env(->(name) { env(name, "32768") })
  try Test.eq(options.context_window, some(32768))
  Test.eq(options.props_url, "http://127.0.0.1:8080/props")
end

private

def env(name: String, window: String) -> Result[String]
  case name
    "AGC_AGENT_CONTEXT_WINDOW" -> ok(window)
    "AGC_AGENT_STATE_DIR" -> ok("/state")
    "AGC_AGENT_DATA_DIR" -> ok("/data")
    _ -> error("not set")
  end
end
