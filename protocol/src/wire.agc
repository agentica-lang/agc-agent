## Decoding shared by the records. Every failure is a `protocol.invalid` error that keeps the JSON error as its cause.

import Kinds from "kinds"

## Decodes `text`; keys the record does not have are ignored, so a reader older than the writer still works.
def decode[T](text: String, codec: Codec[T]) -> Result[T] = invalid(codec.decode(text))

## Decodes `text` and refuses a key the record does not have: a request is checked by its receiver, and a field it does
## not know must not be dropped in silence.
def decode_strict[T](text: String, codec: Codec[T]) -> Result[T]
  json = try invalid(JSON.parse(text))
  case JSON.node(json)
    JSON.Node.Object(fields) ->
      known = codec.members.map { |member| member.name }
      extra = fields.keys.select { |key| not known.include?(key) }
      return error("unknown field: #{extra[0]}", kind: Kinds.KIND_INVALID) if extra.size > 0

      decode(text, codec)
    _ -> error("expected a JSON object", kind: Kinds.KIND_INVALID)
  end
end

def non_empty(field: String, value: String) -> Result[Void]
  return error("#{field} is empty", kind: Kinds.KIND_INVALID) if value == ""

  ok()
end

def non_empty_if_present(field: String, value: Optional[String]) -> Result[Void]
  case value
    some(text) -> non_empty(field, text)
    none -> ok()
  end
end

def non_negative(field: String, value: Int) -> Result[Void]
  return error("#{field} is negative: #{value}", kind: Kinds.KIND_INVALID) if value < 0

  ok()
end

## Every value of an enum, from its first one and a function that gives the next: the function is a `case` over the
## enum, so a new variant fails the check until it has its place in the chain.
def chain[T](first: T, following: Fn[T, Optional[T]]) -> List[T]
  all = [first]
  current = first
  while true
    case following.call(current)
      some(next_value) ->
        all = all.push(next_value)
        current = next_value
      none -> return all
    end
  end

  all
end

## The value of `all` whose name on the wire is `name`; another name is a `protocol.unknown` error.
def lookup[T](all: List[T], name_of: Fn[T, String], what: String, name: String) -> Result[T]
  found = all.find { |value| name_of.call(value) == name }
  case found
    ok(value) -> ok(value)
    error(_) -> error("unknown #{what}: #{name}", kind: Kinds.KIND_UNKNOWN)
  end
end

def option_list[T](value: Optional[T]) -> List[T]
  case value
    some(v) -> [v]
    none -> []
  end
end

## Each field of `records` as `name:type`, a record after another.
def fields(records: List[List[StructMember]]) -> List[String]
  records.map { |members| members.map { |m| "#{m.name}:#{m.type}" }.join(",") }
end

private

def invalid[T](result: Result[T]) -> Result[T]
  case result
    ok(value) -> ok(value)
    error(e) -> error(e.message, kind: Kinds.KIND_INVALID, cause: e)
  end
end
