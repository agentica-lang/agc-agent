## Decoding shared by the records: every failure is a `protocol.invalid` error that keeps the JSON error as its cause.
def decode[T](text: String, codec: Codec[T]) -> Result[T]
  case codec.decode(text)
    ok(value) -> ok(value)
    error(e) -> error(e.message, kind: "protocol.invalid", cause: e)
  end
end

## The value of `all` whose name on the wire is `name`; another name is a `protocol.unknown` error.
def lookup[T](all: List[T], name_of: Fn[T, String], what: String, name: String) -> Result[T]
  found = all.find { |value| name_of.call(value) == name }
  case found
    ok(value) -> ok(value)
    error(_) -> error("unknown #{what}: #{name}", kind: "protocol.unknown")
  end
end
