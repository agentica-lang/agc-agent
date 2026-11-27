import Body from "../src/body"

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
