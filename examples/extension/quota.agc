import Core from "pkg/core/core"

def register(registry: Core.Registry) -> Core.Registry
  Core.add_status_segment(registry, Core.StatusProvider(name: "chatgpt.quota", value: &value))
end

private

def value(context: Core.StatusContext) -> Result[String]
  return ok("") if context.provider != "chatgpt"

  windows = try context.chatgpt_usage.call()
  parts: List[String] = []
  for window in windows
    next if not [18_000, 604_800].include?(window.seconds)

    label = case window.seconds
      18_000 -> "5h"
      _ -> "7d"
    end

    parts = parts.push("#{label} #{try window.remaining.to_i}%")
  end

  ok(parts.join(" · "))
end
