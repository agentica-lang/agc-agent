import Quota from "../src/providers/chatgpt_quota"

def test_quota_windows_are_identified_by_duration_and_report_remaining() -> Result[Void]
  text = <<~JSON
    {"rate_limit": {
      "primary_window": {"limit_window_seconds": 604800, "used_percent": 60, "reset_at": 20},
      "secondary_window": {"limit_window_seconds": 18000, "used_percent": 28, "reset_at": 10}
    }}
  JSON
  windows = try Quota.parse(text)
  try Test.eq(windows.map { |window| window.seconds }, [18_000, 604_800])
  try Test.eq(windows.map { |window| window.remaining }, [72.0, 40.0])
  Test.eq(windows.map { |window| window.reset_at }, [10, 20])
end

def test_quota_ignores_missing_or_invalid_windows() -> Result[Void]
  text = <<~JSON
    {"rate_limit": {
      "primary_window": {"limit_window_seconds": 18000, "reset_at": 10},
      "secondary_window": {"limit_window_seconds": 60, "used_percent": 10, "reset_at": 20}
    }}
  JSON
  try Test.eq((try Quota.parse(text)).size, 0)
  try Test.eq((try Quota.parse("{\"rate_limit\": {}}")).size, 0)
  Test.error?(Quota.parse("not json"))
end

def test_quota_clamps_percentages() -> Result[Void]
  text = <<~JSON
    {"rate_limit": {
      "primary_window": {"limit_window_seconds": 18000, "used_percent": 101, "reset_at": 10},
      "secondary_window": {"limit_window_seconds": 604800, "used_percent": -3, "reset_at": 20}
    }}
  JSON
  Test.eq((try Quota.parse(text)).map { |window| window.remaining }, [0.0, 100.0])
end
