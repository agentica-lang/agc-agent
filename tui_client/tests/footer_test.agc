import Footer from "../src/footer"

# Counts round to the unit shown and never show four digits of one; a cost under a tenth of a cent says so, and a
# huge one is capped; home with a trailing slash is still `~`.
def test_counts_and_costs_round_to_what_is_shown() -> Result[Void]
  try Test.eq(
    [950, 1234, 9949, 9950, 12_345, 999_499, 999_500, 1_250_000].map { |n| Footer.tokens(n) },
    ["950", "1.2k", "9.9k", "10k", "12k", "999k", "1.0M", "1.3M"],
  )

  try Test.eq(
    [0.0, 0.0004, 0.0005, 0.0125, 1.5, 1.0e300].map { |usd| Footer.money(usd) },
    ["$0.000", "<$0.001", "$0.001", "$0.013", "$1.500", "$1000000.000"],
  )

  Test.eq(Footer.place("/home/ana", "/home/ana/", "", "", 20).strip, "~")
end
