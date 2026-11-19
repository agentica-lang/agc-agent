## The subscription windows in ChatGPT's usage response, without credentials or network access.

## A window's duration and reset time in seconds, and its remaining percentage.
struct Window
  seconds: Int
  reset_at: Int
  remaining: Float
end

## The known five-hour and seven-day windows in a usage response, in that order.
def parse(text: String) -> Result[List[Window]]
  json = try JSON.parse(text)
  limits = try JSON.get(json, "rate_limit")
  primary = window(JSON.get(limits, "primary_window"))
  secondary = window(JSON.get(limits, "secondary_window"))
  found = option_list(primary) + option_list(secondary)
  five = found.select { |item| item.seconds == 18_000 }.take(1)
  week = found.select { |item| item.seconds == 604_800 }.take(1)
  ok(five + week)
end

private

def window(value: Result[JSON.Value]) -> Optional[Window]
  case parsed_window(value)
    ok(found) -> some(found)
    error(_) -> none
  end
end

def parsed_window(value: Result[JSON.Value]) -> Result[Window]
  json = try value
  seconds = try JSON.int(try JSON.get(json, "limit_window_seconds"))
  reset = try JSON.int(try JSON.get(json, "reset_at"))
  used = try JSON.float(try JSON.get(json, "used_percent"))
  return error("unknown or invalid quota window") if not [18_000, 604_800].include?(seconds) or reset < 0

  remaining = [[100.0 - used, 0.0].max.unwrap!, 100.0].min.unwrap!
  ok(Window(seconds: seconds, reset_at: reset, remaining: remaining))
end

def option_list[T](value: Optional[T]) -> List[T]
  case value
    some(item) -> [item]
    none -> []
  end
end
