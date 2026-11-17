import Protocol from "pkg/protocol/protocol"
import Footer from "../src/footer"
import Rate from "../src/rate"
import Width from "../src/width"

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

# At 80 columns a long model name keeps its place: the counts lose the part cached, the window and the cache read
# first, then the model is cut; two cells always stand between the left part and the model.
def test_a_narrow_row_drops_counts_before_the_model() -> Result[Void]
  used = Protocol.Usage(
    input: 1200,
    output: 340,
    cache_read: 3600,
    cache_write: 0,
    context: 4800,
    session_cost: some(0.0125),
    window: some(32_000),
    call_output: some(40),
  )

  model = Footer.model("anthropic/claude-sonnet-4-5-20250929", some("high"))
  hints = ["Enter send", "Esc stop"]
  row = Footer.status(["ready"], some(used), hints, model, 80)
  try Test.eq(row, " ready · ↑4.8k ↓40 R3.6k $0.013   (anthropic) claude-sonnet-4-5-20250929 · high ")
  wide = Footer.status(["ready"], some(used), hints, model, 140)
  try Test.assert(wide.include?("R3.6k 75% cached $0.013 15.0%/32k · Enter send"), wide)
  narrow = Footer.status(["ready"], some(used), hints, model, 50)
  try Test.eq(narrow, " ready · ↑4.8k ↓40 $0.013  (anthropic) claude-so… ")
  try Test.eq(Footer.status(["ready"], none, hints, "(local) m", 31), " ready · Enter send  (local) m ")
  Test.eq([row, narrow].map { |r| Width.text(r) }, [80, 50])
end

# The rate of the model's output follows the counts, and a row too narrow for all of it drops the rate first.
def test_a_narrow_row_drops_the_rate_first() -> Result[Void]
  used = Protocol.Usage(
    input: 1200,
    output: 340,
    cache_read: 3600,
    cache_write: 0,
    context: 4800,
    session_cost: some(0.0125),
    window: some(32_000),
    call_output: some(40),
  )

  model = "(local) m"
  full = " ready · ↑4.8k ↓40 R3.6k 75% cached $0.013 15.0%/32k"
  wide = Footer.status(["ready"], some(used), [], model, 140, "~42 tok/s")
  try Test.assert(wide.start_with?("#{full} · ~42 tok/s  "), wide)
  fits = Width.text(full) + Width.text(model) + 3
  Test.eq(Footer.status(["ready"], some(used), [], model, fits, "~42 tok/s"), "#{full}  #{model} ")
end

# While a call streams the rate is estimated at 4 characters a token, once it has streamed for half a second; its usage
# gives the exact rate, its output tokens over the time of its output. No data shows no rate.
def test_the_rate_is_estimated_then_exact() -> Result[Void]
  started = Rate.streamed(none, "Hello", 1000)
  later = Rate.streamed(some(started), "x" * 800, 2000)
  try Test.eq([started.chars, later.chars], [0, 800])
  try Test.eq([Rate.live(later, 1400), Rate.live(started, 3000)], [none, none])
  try Test.eq(Rate.text(Rate.live(later, 3000)), "~100 tok/s")
  call = Protocol.Usage(input: 1, output: 9000, cache_read: 0, cache_write: 0, context: 1, call_output: some(300))
  try Test.eq(Rate.text(Rate.exact(call.with(output_ms: some(1500)))), "200 tok/s")
  try Test.eq([Rate.exact(call), Rate.exact(call.with(output_ms: some(0)))], [none, none])
  Test.eq(Rate.text(none), "")
end
