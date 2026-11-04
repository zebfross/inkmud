//// Grid layout for rooms that don't have coordinates.
////
//// Rooms are now given fixed coordinates when they're built, and the map
//// reads those. This is for worlds built before that: at startup, rooms
//// without coordinates are placed by walking outward from the first room,
//// putting each newly reached room one step away in the exit's direction
//// (north is -y, east is +x, up is +z). Those older rooms never promised
//// that north-then-south leads back to the same square, so when the wanted
//// cell is already taken the room goes to the nearest free cell on the same
//// level instead.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import server/world/types.{type Direction, type Room}

pub type Placed {
  Placed(room: Room, x: Int, y: Int, z: Int)
}

type Cell =
  #(Int, Int, Int)

type Layout {
  Layout(
    rooms: Dict(Int, Room),
    positions: Dict(Int, Cell),
    occupied: Dict(Cell, Int),
  )
}

/// Place `rooms` (the visited ones), starting from the first of `roots` that
/// is among them. Rooms not reachable from there (through visited rooms)
/// are laid out as separate clusters to the east.
pub fn layout(rooms: List(Room), roots: List(Int)) -> List(Placed) {
  let by_id = list.fold(rooms, dict.new(), fn(d, r) { dict.insert(d, r.id, r) })
  let order =
    list.append(
      list.filter(roots, dict.has_key(by_id, _)),
      rooms |> list.map(fn(r) { r.id }) |> list.sort(int.compare),
    )
  let final =
    list.fold(order, Layout(by_id, dict.new(), dict.new()), fn(layout, id) {
      case dict.has_key(layout.positions, id) {
        True -> layout
        False -> {
          let start = #(next_cluster_x(layout), 0, 0)
          layout |> place(id, start) |> spread([id])
        }
      }
    })
  rooms
  |> list.filter_map(fn(r) {
    use #(x, y, z) <- result.map(dict.get(final.positions, r.id))
    Placed(r, x, y, z)
  })
}

fn next_cluster_x(layout: Layout) -> Int {
  case dict.values(layout.positions) {
    [] -> 0
    cells -> 3 + list.fold(cells, 0, fn(m, c) { int.max(m, c.0) })
  }
}

fn place(layout: Layout, id: Int, wanted: Cell) -> Layout {
  let cell = nearest_free(layout.occupied, wanted)
  Layout(
    ..layout,
    positions: dict.insert(layout.positions, id, cell),
    occupied: dict.insert(layout.occupied, cell, id),
  )
}

/// Breadth-first from `queue`, placing each unplaced visited neighbour.
fn spread(layout: Layout, queue: List(Int)) -> Layout {
  case queue {
    [] -> layout
    [id, ..rest] -> {
      let assert Ok(from) = dict.get(layout.positions, id)
      let assert Ok(room) = dict.get(layout.rooms, id)
      let #(layout, added) =
        room.exits
        |> list.sort(fn(a, b) {
          int.compare(direction_rank(a.direction), direction_rank(b.direction))
        })
        |> list.fold(#(layout, []), fn(acc, exit) {
          let #(layout, added) = acc
          case exit.target {
            Some(target) ->
              case
                dict.has_key(layout.rooms, target),
                dict.has_key(layout.positions, target)
              {
                True, False -> #(
                  place(layout, target, step(from, exit.direction)),
                  [target, ..added],
                )
                _, _ -> acc
              }
            None -> acc
          }
        })
      spread(layout, list.append(rest, list.reverse(added)))
    }
  }
}

pub fn step(cell: #(Int, Int, Int), d: Direction) -> #(Int, Int, Int) {
  let #(x, y, z) = cell
  case d {
    types.North -> #(x, y - 1, z)
    types.South -> #(x, y + 1, z)
    types.East -> #(x + 1, y, z)
    types.West -> #(x - 1, y, z)
    types.Up -> #(x, y, z + 1)
    types.Down -> #(x, y, z - 1)
  }
}

fn direction_rank(d: Direction) -> Int {
  case d {
    types.North -> 0
    types.East -> 1
    types.South -> 2
    types.West -> 3
    types.Up -> 4
    types.Down -> 5
  }
}

/// The wanted cell if it's free; otherwise the closest free cell on the same
/// level, searching outward ring by ring.
fn nearest_free(occupied: Dict(Cell, Int), wanted: Cell) -> Cell {
  case dict.has_key(occupied, wanted) {
    False -> wanted
    True -> ring_search(occupied, wanted, 1)
  }
}

fn ring_search(occupied: Dict(Cell, Int), centre: Cell, r: Int) -> Cell {
  let #(cx, cy, z) = centre
  let ring =
    range(-r, r)
    |> list.flat_map(fn(dx) {
      range(-r, r)
      |> list.filter_map(fn(dy) {
        case int.max(int.absolute_value(dx), int.absolute_value(dy)) == r {
          True -> Ok(#(cx + dx, cy + dy, z))
          False -> Error(Nil)
        }
      })
    })
    // Prefer cells closest to the wanted one (straight steps before corners).
    |> list.sort(fn(a, b) {
      int.compare(distance(a, centre), distance(b, centre))
    })
  case list.find(ring, fn(c) { !dict.has_key(occupied, c) }) {
    Ok(cell) -> cell
    Error(Nil) -> ring_search(occupied, centre, r + 1)
  }
}

fn distance(a: Cell, b: Cell) -> Int {
  int.absolute_value(a.0 - b.0) + int.absolute_value(a.1 - b.1)
}

/// from..to inclusive.
fn range(from: Int, to: Int) -> List(Int) {
  case from > to {
    True -> []
    False -> [from, ..range(from + 1, to)]
  }
}
