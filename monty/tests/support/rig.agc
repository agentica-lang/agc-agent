## The command of the fake worker, which replays a fixture of recorded frames.

## The words that start the fake worker on `fixture` (a name in tests/fixtures).
def fake(fixture: String) -> List[String] = [binary(), "tests/support/fake_worker.agc", "tests/fixtures/#{fixture}"]

## The words of a fake worker that never answers.
def silent() -> List[String] = [binary(), "tests/support/fake_worker.agc", "--silent"]

def binary() -> String
  case System.env("AGENTICA")
    ok(path) if path != "" -> path
    _ -> "agentica"
  end
end
