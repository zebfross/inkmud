//// The world's canonical data. Everything here lives in the database; the
//// models only ever propose new instances of it, never edit it freely.

import gleam/int
import gleam/list
import gleam/option.{type Option}
import gleam/string

pub type Region {
  Region(id: String, name: String, theme: String)
}

pub type Exit {
  Exit(
    direction: Direction,
    /// What a player sees of the way out before going through. Once built,
    /// the room on the other side had to honour it.
    hint: String,
    /// Region the room beyond belongs (or will belong) to.
    target_region: String,
    /// `None` until someone (or prefetching) goes through.
    target: Option(Int),
    /// Locked: what bars the way ("an iron gate with a raven-shaped
    /// keyhole"). Opened for good by the one key made for it.
    lock: Option(String),
    /// Blocked by something a tool gets you past (a rusted grate, a sheer
    /// drop). Cleared for good by anyone carrying a tool of its kind.
    obstacle: Option(Obstacle),
  )
}

pub type Obstacle {
  Obstacle(kind: String, desc: String)
}

/// A kind of tool, and the obstacles it gets you past.
pub type ToolKind {
  ToolKind(
    kind: String,
    /// The tool itself, as placed in the world.
    name: String,
    looks: String,
    /// What blocks you, for the model to describe one of ("a rusted grate").
    obstacles: String,
    /// Said when you don't have it.
    needs: String,
    /// Said when you use it ("You lever it open with the iron crowbar.").
    clears: String,
  )
}

pub const tool_kinds = [
  ToolKind(
    kind: "crowbar",
    name: "iron crowbar",
    looks: "a heavy iron crowbar, flattened at one end",
    obstacles: "something that has to be pried open: a rusted grate, boards nailed across the way, a stuck hatch",
    needs: "You'd need something to pry it open.",
    clears: "You lever it open with the iron crowbar; it stays open.",
  ),
  ToolKind(
    kind: "rope",
    name: "coil of rope",
    looks: "a coil of thick hemp rope",
    obstacles: "something you'd need a rope to get past: a sheer drop, broken stairs, a high ledge",
    needs: "You'd need a rope to get past.",
    clears: "You make the coil of rope fast and climb past; you leave a knotted line behind for others.",
  ),
  ToolKind(
    kind: "spade",
    name: "iron-bladed spade",
    looks: "a short spade with an iron blade and a worn ash handle",
    obstacles: "something you'd have to dig through: a heap of fallen rubble, a cave-in of earth and stone, a doorway silted up with mud",
    needs: "You'd need something to dig through it.",
    clears: "You dig a way through with the iron-bladed spade; the passage stays clear.",
  ),
  ToolKind(
    kind: "pole",
    name: "lamplighter's hooked pole",
    looks: "a long wooden pole with an iron hook at its tip",
    obstacles: "something just out of reach that a long hooked pole could bring down: a ladder pulled up, a hatch high overhead, a drawbridge raised",
    needs: "You'd need something long to reach it.",
    clears: "You catch it with the lamplighter's hooked pole and pull it within reach; it stays down.",
  ),
]

pub fn tool_kind(kind: String) -> Result(ToolKind, Nil) {
  list.find(tool_kinds, fn(t) { t.kind == kind })
}

pub type Room {
  Room(
    id: Int,
    region: String,
    name: String,
    description: String,
    /// Fixed visual facts; they feed the art prompt and future descriptions.
    features: List(String),
    items: List(String),
    exits: List(Exit),
    art_url: Option(String),
    /// What the room's picture shows: one or two sentences written with the
    /// description, naming every item, so the art matches the text. Empty for
    /// rooms built before this existed (the art composes one from the facts).
    picture: String,
    /// Grid position, fixed when the room is built: x east, y south, z up.
    /// One room per cell; the room beyond an exit is always one step away.
    x: Int,
    y: Int,
    z: Int,
    /// Pitch dark: without a lit light you see nothing here, and can only
    /// feel your way back toward somewhere lit.
    dark: Bool,
  )
}

pub type Cell =
  #(Int, Int, Int)

pub fn cell(room: Room) -> Cell {
  #(room.x, room.y, room.z)
}

/// The cell one step from `cell` in direction `d`.
pub fn step(cell: Cell, d: Direction) -> Cell {
  let #(x, y, z) = cell
  case d {
    North -> #(x, y - 1, z)
    South -> #(x, y + 1, z)
    East -> #(x + 1, y, z)
    West -> #(x - 1, y, z)
    Up -> #(x, y, z + 1)
    Down -> #(x, y, z - 1)
  }
}

pub type Direction {
  North
  South
  East
  West
  Up
  Down
}

pub const all_directions = [North, South, East, West, Up, Down]

/// Roles an item can have that the game actually does something with. Only
/// these can be picked up (and examined); add one as its mechanic is built.
/// Older items without one of these are scenery.
pub const takeable_roles = ["key", "light", "fuel", "tool", "map", "treasure"]

/// Oil a new lantern holds, and what a tin of oil adds: one unit is used
/// for each step into (or within) a dark place.
pub const lantern_oil = 30

pub fn direction_name(d: Direction) -> String {
  case d {
    North -> "north"
    South -> "south"
    East -> "east"
    West -> "west"
    Up -> "up"
    Down -> "down"
  }
}

pub fn parse_direction(text: String) -> Result(Direction, Nil) {
  case text {
    "n" | "north" -> Ok(North)
    "s" | "south" -> Ok(South)
    "e" | "east" -> Ok(East)
    "w" | "west" -> Ok(West)
    "u" | "up" -> Ok(Up)
    "d" | "down" -> Ok(Down)
    _ -> Error(Nil)
  }
}

pub fn opposite(d: Direction) -> Direction {
  case d {
    North -> South
    South -> North
    East -> West
    West -> East
    Up -> Down
    Down -> Up
  }
}

pub fn find_exit(room: Room, d: Direction) -> Result(Exit, Nil) {
  list.find(room.exits, fn(e) { e.direction == d })
}

/// "An iron gate with a raven keyhole" → "An iron gate with a raven keyhole
/// bars the way. It's locked."; a description that already says what it
/// does ("A sturdy gate bars the way") isn't told twice.
pub fn barred(lock: String) -> String {
  let lock = string.trim(lock)
  let lock = case string.ends_with(lock, ".") {
    True -> string.drop_end(lock, 1)
    False -> lock
  }
  let sentence =
    string.uppercase(string.slice(lock, 0, 1)) <> string.drop_start(lock, 1)
  let says_it =
    list.any(["bar", "block", "seal", "lock"], fn(w) {
      string.contains(string.lowercase(lock), " " <> w)
    })
  case says_it {
    True -> sentence <> ". It's locked."
    False -> sentence <> " bars the way. It's locked."
  }
}

/// "A rusted grate blocks the way. You'd need something to pry it open."
pub fn obstructed(obstacle: Obstacle) -> String {
  let desc = string.trim(obstacle.desc)
  let desc = case string.ends_with(desc, ".") {
    True -> string.drop_end(desc, 1)
    False -> desc
  }
  let sentence =
    string.uppercase(string.slice(desc, 0, 1)) <> string.drop_start(desc, 1)
  let says_it =
    list.any(["bar", "block", "seal"], fn(w) {
      string.contains(string.lowercase(desc), " " <> w)
    })
  let needs = case tool_kind(obstacle.kind) {
    Ok(kind) -> kind.needs
    Error(Nil) -> "You'd need something to get past it."
  }
  case says_it {
    True -> sentence <> ". " <> needs
    False -> sentence <> " blocks the way. " <> needs
  }
}

/// What a treasure map leads to: things worth finding in Vellmoor.
pub type Treasure {
  Treasure(name: String, looks: String)
}

pub const treasures = [
  Treasure(
    "lamplighter's guild ring",
    "a heavy gold signet ring stamped with a lamp",
  ),
  Treasure(
    "silver pocket watch",
    "an engraved silver pocket watch on a broken chain",
  ),
  Treasure(
    "string of river pearls",
    "a string of grey river pearls with a silver clasp",
  ),
  Treasure(
    "purse of old sovereigns",
    "a small leather purse heavy with gold coins",
  ),
  Treasure("jet mourning brooch", "a black jet brooch set in silver"),
  Treasure(
    "bell-founder's medal",
    "a bronze medal stamped with a bell and a date",
  ),
  Treasure(
    "smuggler's silver flask",
    "a dented silver hip flask engraved with a ship",
  ),
  Treasure(
    "cathedral reliquary",
    "a small gilt reliquary box with a cracked crystal lid",
  ),
]

/// Tool kinds that can dig up a cache.
pub const digging_tools = ["spade", "crowbar"]

/// Roughly where a cell is from another, in words: "about 3 streets north
/// and 2 east, one level below here".
pub fn bearing(from: Cell, to: Cell) -> String {
  let #(dx, dy, dz) = #(to.0 - from.0, to.1 - from.1, to.2 - from.2)
  let streets = fn(n: Int, plus: String, minus: String) {
    case n {
      0 -> []
      _ if n > 0 -> [int.to_string(n) <> " " <> plus]
      _ -> [int.to_string(-n) <> " " <> minus]
    }
  }
  let across =
    list.append(streets(dy, "south", "north"), streets(dx, "east", "west"))
  let level = case dz {
    0 -> []
    1 -> ["one level above"]
    -1 -> ["one level below"]
    _ if dz > 0 -> [int.to_string(dz) <> " levels above"]
    _ -> [int.to_string(-dz) <> " levels below"]
  }
  case across, level {
    [], [] -> "right here"
    [], _ -> string.join(level, "") <> " here"
    _, [] -> "about " <> string.join(across, " and ") <> " of here"
    _, _ ->
      "about "
      <> string.join(across, " and ")
      <> ", "
      <> string.join(level, "")
      <> " here"
  }
}
