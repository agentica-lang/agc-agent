# The protobuf primitives: what the worker sends is read back the same, at the edges of each encoding.

import Proto from "../src/proto"

def test_varints_and_zigzag_round_trip_at_their_edges() -> Result[Void]
  for value in [0, 1, 127, 128, 300, 16_384, 4_611_686_018_427_387_903, -1, -9_223_372_036_854_775_808]
    fields = try Proto.fields(Proto.varint_field(3, value))
    try Test.eq([fields[0].number, fields[0].wire, fields[0].value], [3, 0, value])
    signed = try Proto.fields(Proto.sint_field(1, value))
    try Test.eq(Proto.unzigzag(signed[0].value), value)
  end

  Test.eq(Proto.varint(-1).length, 10)
end

def test_fields_read_doubles_strings_and_packed_or_plain_repeats() -> Result[Void]
  message = Bytes.concat([
    Proto.double_field(7, -0.5),
    Proto.string_field(8, "héllo"),
    Proto.packed_field(1, [1, 300, 2]),
    Proto.varint_field(1, 4),
  ])

  fields = try Proto.fields(message)
  try Test.eq(Proto.double(fields, 7), -0.5)
  try Test.eq(Proto.text(fields, 8), "héllo")
  Test.eq(Proto.packed(fields, 1), ok([1, 300, 2, 4]))
end

def test_a_cut_message_is_an_error() -> Result[Void]
  whole = Proto.string_field(8, "hello")
  try Test.error?(Proto.fields(whole.take(whole.length - 1)))
  try Test.error?(Proto.fields(Bytes.from_list([8, 255, 255]).unwrap!))
  eleven = Bytes.from_list([8] + (1..10).map { |_| 255 } + [1]).unwrap!
  try Test.error?(Proto.fields(eleven))
  ten = Bytes.from_list([8] + (1..9).map { |_| 255 } + [1]).unwrap!
  try Test.eq((try Proto.fields(ten))[0].value, -1)
  Test.error?(Proto.fields(Bytes.from_list([11]).unwrap!))
end
