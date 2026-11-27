import Body from "../src/body"

INT64_BOUNDS = "\"minimum\": -9223372036854775808, \"maximum\": 9223372036854775807"

# A bound that a provider can take stays: only the 64-bit ones of an Int field go.
def test_small_bounds_stay_in_a_provider_schema() -> Result[Void]
  schema = try JSON.parse("{\"type\": \"integer\", \"minimum\": 0, \"maximum\": 100}")
  Test.eq(Body.provider_schema(schema), schema)
end

def test_the_64_bit_bounds_are_left_out_of_a_provider_schema() -> Result[Void]
  schema = try JSON.parse(
    "{\"type\": \"integer\", \"minimum\": -9223372036854775808, \"maximum\": 9223372036854775807}",
  )

  Test.eq(Body.provider_schema(schema), try JSON.parse("{\"type\": \"integer\"}"))
end

# A UInt64 field's bound is a BigInt in JSON, and a big Float bound is as large: both go, on each of the four keys; the
# 0 stays.
def test_a_uint64_bound_and_a_big_float_bound_are_left_out_of_a_provider_schema() -> Result[Void]
  schema = try JSON.parse(
    "{\"type\": \"integer\", \"minimum\": 0, \"maximum\": 18446744073709551615, " +
    "\"exclusiveMinimum\": -1e30, \"exclusiveMaximum\": 1.5e300}",
  )

  Test.eq(Body.provider_schema(schema), try JSON.parse("{\"type\": \"integer\", \"minimum\": 0}"))
end

# A tool field named "maximum" is a key of `properties` whose value is an object: it stays, its own 64-bit bound goes.
def test_a_field_named_maximum_stays_in_a_provider_schema() -> Result[Void]
  schema = try JSON.parse(
    "{\"type\": \"object\", \"properties\": {\"maximum\": {\"type\": \"integer\", #{INT64_BOUNDS}}}, " +
    "\"required\": [\"maximum\"]}",
  )

  expected = try JSON.parse(
    "{\"type\": \"object\", \"properties\": {\"maximum\": {\"type\": \"integer\"}}, \"required\": [\"maximum\"]}",
  )

  Test.eq(Body.provider_schema(schema), expected)
end

def test_bounds_are_left_out_in_items_defs_and_arrays_of_a_provider_schema() -> Result[Void]
  schema = try JSON.parse(
    "{\"type\": \"object\", \"properties\": {" +
    "\"ids\": {\"type\": \"array\", \"items\": {\"type\": \"integer\", #{INT64_BOUNDS}}}, " +
    "\"inner\": {\"$ref\": \"#/$defs/Inner\"}, " +
    "\"choice\": {\"anyOf\": [{\"type\": \"integer\", \"maximum\": 18446744073709551615}, {\"type\": \"null\"}]}}, " +
    "\"$defs\": {\"Inner\": {\"type\": \"object\", \"properties\": {\"n\": {\"type\": \"integer\", #{INT64_BOUNDS}}}}}}",
  )

  expected = try JSON.parse(
    "{\"type\": \"object\", \"properties\": {" +
    "\"ids\": {\"type\": \"array\", \"items\": {\"type\": \"integer\"}}, " +
    "\"inner\": {\"$ref\": \"#/$defs/Inner\"}, " +
    "\"choice\": {\"anyOf\": [{\"type\": \"integer\"}, {\"type\": \"null\"}]}}, " +
    "\"$defs\": {\"Inner\": {\"type\": \"object\", \"properties\": {\"n\": {\"type\": \"integer\"}}}}}",
  )

  Test.eq(Body.provider_schema(schema), expected)
end
