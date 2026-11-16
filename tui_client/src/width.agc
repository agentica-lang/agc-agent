## How many terminal columns text takes: 2 for East Asian wide characters and most emoji, 0 for combining marks and
## zero-width characters, else 1. Pure.

ZERO = [0x0300..0x036f, 0x200b..0x200f, 0xfe00..0xfe0f]
WIDE = [
  0x1100..0x115f,
  0x2e80..0x303e,
  0x3041..0x33ff,
  0x3400..0x4dbf,
  0x4e00..0x9fff,
  0xa000..0xa4cf,
  0xac00..0xd7a3,
  0xf900..0xfaff,
  0xfe30..0xfe4f,
  0xff00..0xff60,
  0xffe0..0xffe6,
  0x1f300..0x1f64f,
  0x1f900..0x1f9ff,
  0x20000..0x3fffd,
]

def char(c: String) -> Int
  code = c.code
  return 1 if code < 0x0300
  return 0 if within?(ZERO, code)
  return 2 if within?(WIDE, code)

  1
end

def text(s: String) -> Int = s.split("").map { |c| char(c) }.sum

## The longest start of `s` that fits in `columns`, and the rest.
def cut(s: String, columns: Int) -> List[String]
  used = 0
  count = 0
  for c in s.split("")
    used = used + char(c)
    break if used > columns

    count = count + 1
  end

  [s.slice(0, count), s.slice(count, s.length - count)]
end

private

def within?(ranges: List[Range], code: Int) -> Bool = ranges.any? { |range| range.include?(code) }
