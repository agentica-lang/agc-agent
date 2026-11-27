## A session's saved tool results and their bounded representation in model history.

import Spec from "spec"

NAME = "read_tool_output"
INLINE_BYTES = 8_192
PREVIEW_CHARS = 1_024
PAGE_CHARS = 4_096
MARKER = "[tool output artifact: "

struct Port
  save: Fn[String, Result[String]]
  read: Fn[String, Result[String]]
end

def tool(port: Port) -> Spec.Tool
  Spec.Tool(
    name: NAME,
    description: "Read a page of saved tool output in this session by artifact ID.",
    input_schema: JSON.schema(Args),
    asks: false,
    target: ->(_ctx, input) { ok((try Spec.args(input, Args.codec)).id) },
    run: ->(_ctx, input) { page(port, try Spec.args(input, Args.codec)) },
  )
end

## Saves a tool result, or gives an explicit bounded fallback when storage is unavailable.
def saved(text: String, port: Optional[Port], preview: Int) -> String
  if port.some?
    case port.unwrap!.save.call(text)
      ok(id) ->
        notice = "#{MARKER}#{id}] #{text.bytesize} bytes; use #{NAME} with this ID."
        return with_preview(notice, text, preview)
      error(_) -> nil
    end
  end

  with_preview("#{UNSAVED} #{text.bytesize} bytes; the rest was not saved.]", text, preview)
end

## The preview of an existing reference can shrink without storing the reference itself.
def shortened(text: String, port: Optional[Port], preview: Int) -> String
  if text.start_with?(MARKER) or text.start_with?(UNSAVED)
    notice = text.split("\n").first
    return text if notice.length == text.length

    if notice.length <= NOTICE_CHARS
      rest = text.slice(notice.length + 1, text.length - notice.length - 1)
      return with_preview(notice, rest, preview)
    end
  end

  saved(text, port, preview)
end

private

UNSAVED = "[tool output shortened:"
NOTICE_CHARS = 180

struct Args
  id: String
  offset: Optional[Int] = none
end

def with_preview(notice: String, text: String, preview: Int) -> String
  return notice if preview == 0 or text.empty?

  "#{notice}\n#{text.slice(0, [preview, text.length].min.unwrap!)}"
end

def page(port: Port, args: Args) -> Result[String]
  offset = args.offset.unwrap_or(0)
  return error("offset must not be negative") if offset < 0

  text = try port.read.call(args.id)
  return error("offset exceeds the artifact's #{text.length} characters") if offset > text.length

  to = [offset + PAGE_CHARS, text.length].min.unwrap!
  notice = "characters #{offset}–#{to} of #{text.length}; end of output"
  if to < text.length
    notice = "characters #{offset}–#{to} of #{text.length}; next offset: #{to}"
  end

  ok("[#{notice}]\n#{text.slice(offset, to - offset)}")
end
