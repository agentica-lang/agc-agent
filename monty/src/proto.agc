## The protobuf wire format, as much as `monty.proto` needs: varints, zigzag, doubles and length-delimited fields.
## A message is written as the concatenation of its fields, and read as the list of its fields in order.

import Binary from "std/binary"

WIRE_VARINT = 0
WIRE_FIXED64 = 1
WIRE_LEN = 2
WIRE_FIXED32 = 5

## One field of a read message: `value` for a varint or fixed field (a double as its bits), `data` for a
## length-delimited one.
struct Field
  number: Int
  wire: Int
  value: Int = 0
  data: Bytes
end

def varint_field(number: Int, value: Int) -> Bytes = Bytes.concat([key(number, WIRE_VARINT), varint(value)])

def sint_field(number: Int, value: Int) -> Bytes = varint_field(number, zigzag(value))

def bool_field(number: Int, value: Bool) -> Bytes
  return varint_field(number, 1) if value

  varint_field(number, 0)
end

def double_field(number: Int, value: Float) -> Bytes
  Bytes.concat([key(number, WIRE_FIXED64), Binary.write_f64_le(value)])
end

def bytes_field(number: Int, data: Bytes) -> Bytes = Bytes.concat([key(number, WIRE_LEN), varint(data.length), data])

def string_field(number: Int, text: String) -> Bytes = bytes_field(number, text.bytes)

## A repeated varint field, packed as proto3 writes it.
def packed_field(number: Int, values: List[Int]) -> Bytes
  bytes_field(number, Bytes.concat(values.map { |value| varint(value) }))
end

## The unsigned varint of `value`; a negative one takes ten bytes, as its 64-bit two's complement.
def varint(value: Int) -> Bytes
  out: List[Int] = []
  rest = value
  while true
    low = rest.bit_and(127)
    rest = rest.shift_right_unsigned(7)
    if rest == 0
      out = out.push(low)
      break
    end

    out = out.push(low.bit_or(128))
  end

  Bytes.from_list(out).unwrap!
end

def zigzag(value: Int) -> Int = value.shift_left(1).bit_xor(value.shift_right(63))

def unzigzag(value: Int) -> Int = value.shift_right_unsigned(1).bit_xor(-value.bit_and(1))

## The fields of a message, in order. A truncated field, a varint over ten bytes or an unknown wire type is an error.
def fields(data: Bytes) -> Result[List[Field]]
  out: List[Field] = []
  at = 0
  while at < data.length
    head = try read_varint(data, at)
    at = head.next
    number = head.value.shift_right_unsigned(3)
    wire = head.value.bit_and(7)
    case wire
      0 ->
        read = try read_varint(data, at)
        out = out.push(Field(number: number, wire: wire, value: read.value, data: "".bytes))
        at = read.next
      1 ->
        bits = try fixed(data, at, 8)
        out = out.push(Field(number: number, wire: wire, value: bits, data: "".bytes))
        at = at + 8
      2 ->
        size = try read_varint(data, at)
        start = size.next
        return error("protobuf: a field runs past the message") if size.value < 0 or start + size.value > data.length

        out = out.push(Field(number: number, wire: wire, data: data.slice(start, size.value)))
        at = start + size.value
      5 ->
        bits = try fixed(data, at, 4)
        out = out.push(Field(number: number, wire: wire, value: bits, data: "".bytes))
        at = at + 4
      _ -> return error("protobuf: unknown wire type #{wire}")
    end
  end

  ok(out)
end

## The last varint of field `number`, 0 when it is absent.
def uint(fields: List[Field], number: Int) -> Int
  value = 0
  for field in fields
    if field.number == number and field.wire == WIRE_VARINT
      value = field.value
    end
  end

  value
end

def has?(fields: List[Field], number: Int) -> Bool = fields.any? { |field| field.number == number }

## The last length-delimited field `number`, empty when it is absent.
def data(fields: List[Field], number: Int) -> Bytes
  found = "".bytes
  for field in fields
    if field.number == number and field.wire == WIRE_LEN
      found = field.data
    end
  end

  found
end

def text(fields: List[Field], number: Int) -> String = utf8(data(fields, number))

def all_data(fields: List[Field], number: Int) -> List[Bytes]
  fields.select { |field| field.number == number and field.wire == WIRE_LEN }.map { |field| field.data }
end

def double(fields: List[Field], number: Int) -> Float
  bits = 0
  for field in fields
    if field.number == number and field.wire == WIRE_FIXED64
      bits = field.value
    end
  end

  Float.from_bits(bits)
end

## A repeated varint field, packed or not.
def packed(fields: List[Field], number: Int) -> Result[List[Int]]
  values: List[Int] = []
  for field in (fields.select { |f| f.number == number })
    if field.wire == WIRE_VARINT
      values = values.push(field.value)
    elsif field.wire == WIRE_LEN
      at = 0
      while at < field.data.length
        read = try read_varint(field.data, at)
        values = values.push(read.value)
        at = read.next
      end
    end
  end

  ok(values)
end

def utf8(data: Bytes) -> String
  case Bytes.decode(data, "utf-8")
    ok(text) -> text
    error(_) -> "<#{data.length} bytes>"
  end
end

private

struct Read
  value: Int
  next: Int
end

def key(number: Int, wire: Int) -> Bytes = varint(number.shift_left(3).bit_or(wire))

def read_varint(data: Bytes, from: Int) -> Result[Read]
  value = 0
  shift = 0
  at = from
  while true
    return error("protobuf: a varint runs past the message") if at >= data.length
    return error("protobuf: a varint is longer than ten bytes") if shift > 63

    byte = data.at(at)
    value = value.bit_or(byte.bit_and(127).shift_left(shift))
    at = at + 1
    break if byte < 128

    shift = shift + 7
  end

  ok(Read(value: value, next: at))
end

def fixed(data: Bytes, at: Int, size: Int) -> Result[Int]
  return error("protobuf: a fixed field runs past the message") if at + size > data.length
  return Binary.read_u32_le(data, at) if size == 4

  low = try Binary.read_u32_le(data, at)
  high = try Binary.read_u32_le(data, at + 4)
  ok(high.shift_left(32).bit_or(low))
end
