## The keys of the actions that `keys` of the config may move. The handlers know each action by its default key, so a key
## in effect becomes the default event of its action before any handler sees it, and the default key of an action that
## moved does nothing. Pure.

import Client from "pkg/client/client"
import TUI from "pkg/tui/tui"

## The event as the handlers read it: the key of an action in effect is the default key of that action, and the default
## key of an action that moved is a key that does nothing.
def translated(bindings: Client.Bindings, event: TUI.Event) -> TUI.Event
  for name in option_list(name_of(event))
    for action in option_list(Client.action_of(bindings, name))
      return event_of(Client.default_of(action))
    end

    moved = Client.ACTIONS.any? { |a| a.key == name and Client.key_of(bindings, a.name) != name }
    return TUI.Event.Key(TUI.Key.F(0), TUI.Mods()) if moved
  end

  event
end

## The name of the key of an event as `keys` spells it, none for an event that is no key of an action.
def name_of(event: TUI.Event) -> Optional[String]
  case event
    TUI.Event.Key(TUI.Key.Ctrl(c), mods) if not mods.alt -> some("ctrl+#{c.downcase}")
    TUI.Event.Char(c, mods) if mods.alt and not mods.ctrl -> some("alt+#{c.downcase}")
    TUI.Event.Key(TUI.Key.BackTab, _) -> some("shift+tab")
    TUI.Event.Key(TUI.Key.F(n), _) -> some("f#{n}")
    TUI.Event.Key(TUI.Key.PageUp, _) -> some("pgup")
    TUI.Event.Key(TUI.Key.PageDown, _) -> some("pgdn")
    _ -> none
  end
end

## The event that a key name stands for.
def event_of(name: String) -> TUI.Event
  case name
    "shift+tab" -> TUI.Event.Key(TUI.Key.BackTab, TUI.Mods())
    "pgup" -> TUI.Event.Key(TUI.Key.PageUp, TUI.Mods())
    "pgdn" -> TUI.Event.Key(TUI.Key.PageDown, TUI.Mods())
    _ if name.start_with?("ctrl+") -> TUI.Event.Key(TUI.Key.Ctrl(name.slice(5, 1)), TUI.Mods())
    _ if name.start_with?("alt+") -> TUI.Event.Char(name.slice(4, 1), TUI.Mods(alt: true))
    _ -> TUI.Event.Key(TUI.Key.F(name.slice(1, name.length - 1).to_i.unwrap_or(0)), TUI.Mods())
  end
end

private

def option_list[T](value: Optional[T]) -> List[T]
  case value
    some(v) -> [v]
    none -> []
  end
end
