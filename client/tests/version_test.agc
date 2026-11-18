# How two versions compare: dated ones as text, a dotted one older than any dated one, and nothing said when one side
# does not say its version.

import Version from "../src/version"

struct Row
  client: String
  server: String
  age: Version.Age
end

def test_the_age_of_the_server_against_the_client() -> Result[Void]
  dated = "20261118000000"
  cases = [
    Row(client: dated, server: dated, age: Version.Age.Same),
    Row(client: dated, server: "20260101000000", age: Version.Age.Older),
    Row(client: dated, server: "20270101000000", age: Version.Age.Newer),
    Row(client: dated, server: "0.0.1", age: Version.Age.Older),
    Row(client: "0.0.1", server: dated, age: Version.Age.Newer),
    Row(client: "0.0.1", server: "0.0.2", age: Version.Age.Unknown),
    Row(client: "unknown", server: dated, age: Version.Age.Unknown),
    Row(client: dated, server: "unknown", age: Version.Age.Unknown),
    Row(client: dated, server: "", age: Version.Age.Unknown),
    Row(client: "", server: dated, age: Version.Age.Unknown),
    Row(client: dated, server: "2026111800000x", age: Version.Age.Unknown),
    Row(client: dated, server: "0..1", age: Version.Age.Unknown),
  ]

  for row in cases
    try Test.eq(row.with(age: Version.age(row.client, row.server)), row)
  end

  ok()
end

def test_only_a_dated_or_dotted_version_or_unknown_is_shown() -> Result[Void]
  for version in ["20261118000000", "0.0.1", "unknown"]
    try Test.eq(Version.shown_version(version), version)
  end

  for version in ["", "#{String.from_code(27)}[2J", "2026-11-18", "a.b"]
    try Test.eq(Version.shown_version(version), "another version")
  end

  ok()
end
