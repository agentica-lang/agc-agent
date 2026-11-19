## The keys of the full screen that the user may change: the `keys` map of the config file, from the name of an action to
## the name of a key. A key is named `ctrl+x`, `alt+x`, `shift+tab`, `f1` to `f12`, `pgup` or `pgdn`. Only the actions of
## ACTIONS can move: line editing, Esc, Enter, Ctrl+C, the answers of an approval and the word moves of Alt+B and Alt+F
## are fixed, and a key that one of them uses is refused. Pure.

import Protocol from "pkg/protocol/protocol"

## The actions in the order that `/help` and the hints list them.
ACTIONS = [
  Action(name: "cycle_profile", key: "shift+tab", about: "profile"),
  Action(name: "thinking_level", key: "f2", about: "thinking level"),
  Action(name: "show_thinking", key: "ctrl+t", about: "show thinking"),
  Action(name: "show_tools", key: "ctrl+o", about: "show tool output"),
  Action(name: "logs", key: "ctrl+p", about: "logs"),
  Action(name: "side_focus", key: "f6", about: "move the focus between the side panel and the transcript"),
  Action(name: "edit_prompt", key: "ctrl+g", about: "edit the prompt in $VISUAL or $EDITOR"),
  Action(name: "page_up", key: "pgup", about: "scroll up"),
  Action(name: "page_down", key: "pgdn", about: "scroll down"),
]

## One action: the name that `keys` uses, its key when the config says none, and what it does for the hints.
struct Action
  name: String
  key: String
  about: String
end

## The keys in effect, an action and its key each, and a warning for every entry of the config that was not taken.
struct Bindings
  keys: Map[String, String]
  warnings: List[String] = []
end

## The keys when the config changes none.
def defaults() -> Bindings
  keys: Map[String, String] = {}
  for action in ACTIONS
    keys = keys.put(action.name, action.key)
  end

  Bindings(keys: keys)
end

## The keys in effect for the entries of the config. An unknown action, a key that is not named by the grammar or that a
## fixed function uses, and a key given to two actions, are warnings, and the default stays for each of those entries.
def effective(settings: List[Protocol.KeySetting]) -> Bindings
  warnings: List[String] = []
  chosen: Map[String, String] = {}
  for setting in settings
    if not known?(setting.action)
      warnings = warnings.push("keys: #{setting.action} is not an action (one of #{names().join(", ")})")
      next
    end

    case parse(setting.key)
      ok(key) -> chosen = chosen.put(setting.action, key)
      error(e) -> warnings = warnings.push("keys: #{setting.action}: #{e.message}")
    end
  end

  keys = defaults().keys
  for action in chosen.keys
    keys = keys.put(action, chosen[action])
  end

  # A key that two actions have: the entries of the config that hold it go back to their default, until none is shared.
  while true
    shared = clashing(keys)
    break if shared.empty?

    back = chosen.keys.select { |action| shared.include?(keys[action]) }
    break if back.empty?

    for action in back
      warnings = warnings.push(
        "keys: #{action}: #{label(keys[action])} is used by another action; it stays #{label(default_of(action))}",
      )

      keys = keys.put(action, default_of(action))
      chosen = chosen.delete(action)
    end
  end

  Bindings(keys: keys, warnings: warnings)
end

## The name of a key as `effective` keeps it: lower case, `ctrl+p`, `alt+t`, `shift+tab`, `f2`, `pgup`, `pgdn`; an error
## for a name the grammar does not have, or that a fixed function uses.
def parse(text: String) -> Result[String]
  name = text.strip.downcase
  return ok(name) if name == "shift+tab" or name == "pgup" or name == "pgdn"
  return error("esc is used by the screen and cannot be changed") if name == "esc"

  return ok(name) if function_key?(name)

  if name.start_with?("ctrl+") and letter?(name.slice(5, name.length - 5))
    return error("#{label(name)} is used by line editing or an approval") if FIXED.include?(name)

    return ok(name)
  end

  if name.start_with?("alt+") and letter?(name.slice(4, name.length - 4))
    return error("#{label(name)} is used by line editing") if FIXED.include?(name)

    return ok(name)
  end

  error("#{text.inspect} is not a key (ctrl+x, alt+x, shift+tab, f1 to f12, pgup or pgdn)")
end

## The key of `action`.
def key_of(bindings: Bindings, action: String) -> String = bindings.keys.get(action).unwrap_or(default_of(action))

## The action that has `key`, none for a key that no action has.
def action_of(bindings: Bindings, key: String) -> Optional[String]
  case (bindings.keys.keys.find { |name| bindings.keys[name] == key })
    ok(name) -> some(name)
    error(_) -> none
  end
end

## The default key of `action`, empty for a name that is none.
def default_of(action: String) -> String
  case (ACTIONS.find { |a| a.name == action })
    ok(found) -> found.key
    error(_) -> ""
  end
end

## A key as a person reads it: `Ctrl+P`, `Alt+T`, `Shift+Tab`, `F2`, `PgUp`.
def label(key: String) -> String
  case key
    "pgup" -> "PgUp"
    "pgdn" -> "PgDn"
    "shift+tab" -> "Shift+Tab"
    _ ->
      return "F#{key.slice(1, key.length - 1)}" if key.start_with?("f")

      parts = key.split("+")
      "#{capital(parts[0])}+#{parts[1].upcase}"
  end
end

## A key for the key hints of the status line, short: `^P`, `⇧Tab`, `Alt+T`, `F2`, `PgUp`.
def short(key: String) -> String
  return "⇧Tab" if key == "shift+tab"
  return "^#{key.slice(5, 1).upcase}" if key.start_with?("ctrl+")

  label(key)
end

## The names of the actions.
def names() -> List[String] = ACTIONS.map { |action| action.name }

private

# The keys that fixed functions use: line editing, quit, the answers of an approval, the new line, Enter, Tab and
# Backspace (which terminals send as Ctrl+M, Ctrl+I and Ctrl+H), and the word moves.
FIXED = [
  "ctrl+c", "ctrl+d", "ctrl+j", "ctrl+m", "ctrl+i", "ctrl+h", "ctrl+a", "ctrl+e", "ctrl+w", "ctrl+u", "ctrl+k",
  "ctrl+y", "ctrl+n", "alt+b", "alt+f",
]

DIGITS = "0123456789".split("")
LETTERS = "abcdefghijklmnopqrstuvwxyz".split("")

def known?(action: String) -> Bool = ACTIONS.any? { |a| a.name == action }

def function_key?(name: String) -> Bool
  return false if not name.start_with?("f") or name.length < 2 or name.length > 3

  rest = name.slice(1, name.length - 1)
  digits = rest.split("").all? { |c| DIGITS.include?(c) }
  return false if not digits

  number = rest.to_i.unwrap_or(0)
  number >= 1 and number <= 12 and rest == "#{number}"
end

def letter?(text: String) -> Bool = text.length == 1 and LETTERS.include?(text)

def capital(word: String) -> String = "#{word.slice(0, 1).upcase}#{word.slice(1, word.length - 1)}"

# The keys that more than one action has.
def clashing(keys: Map[String, String]) -> List[String]
  seen: List[String] = []
  shared: List[String] = []
  for action in keys.keys
    key = keys[action]
    if seen.include?(key)
      shared = shared.push(key)
    end

    seen = seen.push(key)
  end

  shared
end
