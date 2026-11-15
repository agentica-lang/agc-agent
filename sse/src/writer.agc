## The writer of the `text/event-stream` format.

import {Event} from "reader"

## The text of one event, ending with its blank line. Each line of `data` becomes one `data:` line. Error
## (`argument`): a line end in `name` or `id`, which would start another field.
def encode(event: Event) -> Result[String]
  if line_end?(event.name) or line_end?(event.id)
    return error("sse: line end in the event name or id: #{event.name.inspect} #{event.id.inspect}", kind: "argument")
  end

  fields: List[String] = []
  if event.name != "message"
    fields = fields.push("event: #{event.name}")
  end

  if not event.id.empty?
    fields = fields.push("id: #{event.id}")
  end

  data = event.data.replace("\r\n", "\n").replace("\r", "\n").split("\n") |> map(->(line) { "data: #{line}" })

  ok((fields + data).map { |line| "#{line}\n" }.join("") + "\n")
end

private

def line_end?(text: String) -> Bool = text.include?("\n") or text.include?("\r")
