//// The world's canonical data. Everything here lives in the database; the
//// models only ever propose new instances of it, never edit it freely.

import gleam/list
import gleam/option.{type Option}

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
  )
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
    /// Grid position, fixed when the room is built: x east, y south, z up.
    /// One room per cell; the room beyond an exit is always one step away.
    x: Int,
    y: Int,
    z: Int,
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
