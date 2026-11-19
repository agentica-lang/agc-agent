import Client from "../client"
import Protocol from "pkg/protocol/protocol"

# No entry changes nothing; an entry moves its action, and two actions may swap their keys.
def test_keys_in_effect_follow_the_config() -> Result[Void]
  plain = Client.defaults()
  try Test.eq(Client.effective([]), plain)
  try Test.eq(Client.key_of(plain, "cycle_profile"), "shift+tab")
  moved = Client.effective([setting("thinking_level", " Alt+T "), setting("logs", "F9")])
  try Test.eq([Client.key_of(moved, "thinking_level"), Client.key_of(moved, "logs")], ["alt+t", "f9"])
  try Test.eq(moved.warnings, [])
  swapped = Client.effective([setting("thinking_level", "shift+tab"), setting("cycle_profile", "f2")])
  try Test.eq([Client.key_of(swapped, "thinking_level"), Client.key_of(swapped, "cycle_profile")], ["shift+tab", "f2"])
  try Test.eq(swapped.warnings, [])
  try Test.eq(Client.action_of(swapped, "f2"), some("cycle_profile"))
  try Test.eq(Client.action_of(swapped, "f12"), none)
  try Test.eq(
    [Client.label("alt+t"), Client.label("shift+tab"), Client.label("f2"), Client.label("pgup")],
    ["Alt+T", "Shift+Tab", "F2", "PgUp"],
  )

  Test.eq([Client.short("ctrl+p"), Client.short("shift+tab"), Client.short("f6")], ["^P", "⇧Tab", "F6"])
end

# An unknown action, a name that is no key, a key that a fixed function uses, and a key two actions have, are warnings,
# and the default stays for each entry.
def test_a_bad_entry_is_a_warning_and_keeps_the_default() -> Result[Void]
  bad = Client.effective([
    setting("nothing", "f9"),
    setting("logs", "f13"),
    setting("show_tools", "ctrl+c"),
    setting("edit_prompt", "esc"),
    setting("show_thinking", "alt+b"),
    setting("side_focus", "f2"),
  ])

  try Test.eq(bad.warnings.size, 6)
  try Test.assert(bad.warnings[0].include?("nothing") and bad.warnings[0].include?("cycle_profile"), "#{bad.warnings}")
  try Test.eq(Client.key_of(bad, "logs"), "ctrl+p")
  try Test.eq(Client.key_of(bad, "show_tools"), "ctrl+o")
  try Test.eq(Client.key_of(bad, "edit_prompt"), "ctrl+g")
  try Test.eq(Client.key_of(bad, "show_thinking"), "ctrl+t")
  # `side_focus` took the key of `thinking_level`, which stays: the entry goes back.
  try Test.eq([Client.key_of(bad, "side_focus"), Client.key_of(bad, "thinking_level")], ["f6", "f2"])
  try Test.assert(bad.warnings.any? { |w| w.include?("side_focus") and w.include?("F2") }, "#{bad.warnings}")
  twice = Client.effective([setting("logs", "f9"), setting("side_focus", "f9")])
  try Test.eq([Client.key_of(twice, "logs"), Client.key_of(twice, "side_focus")], ["ctrl+p", "f6"])
  Test.eq(twice.warnings.size, 2)
end

def setting(action: String, key: String) -> Protocol.KeySetting = Protocol.KeySetting(action: action, key: key)
