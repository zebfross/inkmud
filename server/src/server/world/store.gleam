//// SQLite persistence: the single source of truth for the world. A room,
//// once written, is never regenerated — later visitors read the same rows.

import gleam/dynamic/decode
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import server/world/types.{
  type Direction, type Exit, type Region, type Room, Exit, Region, Room,
}
import sqlight.{type Connection}

pub type Store =
  Connection

const schema = "
create table if not exists regions (
  id text primary key,
  name text not null,
  theme text not null
);
create table if not exists rooms (
  id integer primary key autoincrement,
  region_id text not null references regions(id),
  name text not null,
  description text not null,
  features text not null default '',
  art_url text
);
create table if not exists exits (
  room_id integer not null references rooms(id),
  direction text not null,
  hint text not null,
  target_region text not null,
  target_id integer references rooms(id),
  primary key (room_id, direction)
);
create table if not exists items (
  id integer primary key autoincrement,
  name text not null,
  room_id integer references rooms(id),
  holder text
);
create table if not exists players (
  name text primary key,
  room_id integer not null references rooms(id)
);
create table if not exists visits (
  player text not null,
  room_id integer not null references rooms(id),
  primary key (player, room_id)
);
"

pub fn open(path: String) -> Store {
  let assert Ok(conn) = sqlight.open(path)
  let assert Ok(Nil) = sqlight.exec("pragma journal_mode = wal;", conn)
  let assert Ok(Nil) = sqlight.exec(schema, conn)
  // Grid coordinates arrived after the first worlds were built: add the
  // columns to older databases. Rooms without them are placed at startup
  // (see `rooms_without_cell`). NULLs don't collide in a unique index.
  list.each(["x", "y", "z"], fn(column) {
    case has_column(conn, "rooms", column) {
      True -> Nil
      False -> {
        let assert Ok(Nil) =
          sqlight.exec(
            "alter table rooms add column " <> column <> " integer;",
            conn,
          )
        Nil
      }
    }
  })
  let assert Ok(Nil) =
    sqlight.exec(
      "create unique index if not exists rooms_cell on rooms (x, y, z);",
      conn,
    )
  conn
}

fn has_column(conn: Store, table: String, column: String) -> Bool {
  sqlight.query(
    "select name from pragma_table_info(?)",
    conn,
    [sqlight.text(table)],
    decode.field(0, decode.string, decode.success),
  )
  |> result.unwrap([])
  |> list.contains(column)
}

pub fn exec(store: Store, sql: String) -> Nil {
  let assert Ok(Nil) = sqlight.exec(sql, store)
  Nil
}

/// Dev only: delete the whole world and write it again with `seed`.
/// Ids restart from 1. Returns what `seed` returns (the start room).
pub fn wipe_and(store: Store, seed: fn(Store) -> Int) -> Int {
  exec(
    store,
    "begin;
    delete from visits; delete from items; delete from players; delete from exits;
    delete from rooms; delete from regions;
    delete from sqlite_sequence;
    commit;",
  )
  seed(store)
}

// REGIONS ---------------------------------------------------------------------

pub fn insert_region(store: Store, region: Region) -> Nil {
  let assert Ok(_) =
    sqlight.query(
      "insert or replace into regions (id, name, theme) values (?, ?, ?)",
      store,
      [
        sqlight.text(region.id),
        sqlight.text(region.name),
        sqlight.text(region.theme),
      ],
      decode.success(Nil),
    )
  Nil
}

pub fn region(store: Store, id: String) -> Result(Region, Nil) {
  let decoder = {
    use id <- decode.field(0, decode.string)
    use name <- decode.field(1, decode.string)
    use theme <- decode.field(2, decode.string)
    decode.success(Region(id:, name:, theme:))
  }
  case
    sqlight.query(
      "select id, name, theme from regions where id = ?",
      store,
      [sqlight.text(id)],
      decoder,
    )
  {
    Ok([r]) -> Ok(r)
    _ -> Error(Nil)
  }
}

pub fn regions(store: Store) -> List(Region) {
  let decoder = {
    use id <- decode.field(0, decode.string)
    use name <- decode.field(1, decode.string)
    use theme <- decode.field(2, decode.string)
    decode.success(Region(id:, name:, theme:))
  }
  sqlight.query("select id, name, theme from regions", store, [], decoder)
  |> result.unwrap([])
}

// ROOMS -----------------------------------------------------------------------

pub fn room_count(store: Store) -> Int {
  case
    sqlight.query(
      "select count(*) from rooms",
      store,
      [],
      decode.field(0, decode.int, decode.success),
    )
  {
    Ok([n]) -> n
    _ -> 0
  }
}

pub fn load_room(store: Store, id: Int) -> Result(Room, Nil) {
  let decoder = {
    use region <- decode.field(0, decode.string)
    use name <- decode.field(1, decode.string)
    use description <- decode.field(2, decode.string)
    use features <- decode.field(3, decode.string)
    use art_url <- decode.field(4, decode.optional(decode.string))
    use x <- decode.field(5, decode.optional(decode.int))
    use y <- decode.field(6, decode.optional(decode.int))
    use z <- decode.field(7, decode.optional(decode.int))
    decode.success(#(region, name, description, features, art_url, #(x, y, z)))
  }
  use row <- result.try(
    case
      sqlight.query(
        "select region_id, name, description, features, art_url, x, y, z from rooms where id = ?",
        store,
        [sqlight.int(id)],
        decoder,
      )
    {
      Ok([row]) -> Ok(row)
      _ -> Error(Nil)
    },
  )
  let #(region, name, description, features, art_url, #(x, y, z)) = row
  Ok(Room(
    id:,
    region:,
    name:,
    description:,
    features: split_lines(features),
    items: room_items(store, id),
    exits: exits(store, id),
    art_url:,
    // Only rooms from before coordinates existed lack them, and those are
    // placed at startup before anyone plays.
    x: option.unwrap(x, 0),
    y: option.unwrap(y, 0),
    z: option.unwrap(z, 0),
  ))
}

/// The room at a grid cell, if one has been built there.
pub fn room_at(store: Store, cell: types.Cell) -> Option(Int) {
  let #(x, y, z) = cell
  case
    sqlight.query(
      "select id from rooms where x = ? and y = ? and z = ?",
      store,
      [sqlight.int(x), sqlight.int(y), sqlight.int(z)],
      decode.field(0, decode.int, decode.success),
    )
  {
    Ok([id]) -> Some(id)
    _ -> None
  }
}

/// Ids of rooms that have no coordinates yet (built before they existed).
pub fn rooms_without_cell(store: Store) -> List(Int) {
  sqlight.query(
    "select id from rooms where x is null order by id",
    store,
    [],
    decode.field(0, decode.int, decode.success),
  )
  |> result.unwrap([])
}

pub fn all_room_ids(store: Store) -> List(Int) {
  sqlight.query(
    "select id from rooms order by id",
    store,
    [],
    decode.field(0, decode.int, decode.success),
  )
  |> result.unwrap([])
}

pub fn set_cell(store: Store, room_id: Int, cell: types.Cell) -> Nil {
  let #(x, y, z) = cell
  let assert Ok(_) =
    sqlight.query(
      "update rooms set x = ?, y = ?, z = ? where id = ?",
      store,
      [sqlight.int(x), sqlight.int(y), sqlight.int(z), sqlight.int(room_id)],
      decode.success(Nil),
    )
  Nil
}

/// Give a room a new way out (one it didn't have when built), unless it
/// already has one in that direction.
pub fn add_exit(store: Store, room_id: Int, e: NewExit) -> Nil {
  let assert Ok(_) =
    sqlight.query(
      "insert or ignore into exits (room_id, direction, hint, target_region, target_id) values (?, ?, ?, ?, ?)",
      store,
      [
        sqlight.int(room_id),
        sqlight.text(types.direction_name(e.direction)),
        sqlight.text(e.hint),
        sqlight.text(e.target_region),
        sqlight.nullable(sqlight.int, e.target),
      ],
      decode.success(Nil),
    )
  Nil
}

fn exits(store: Store, room_id: Int) -> List(Exit) {
  let decoder = {
    use direction <- decode.field(0, decode.string)
    use hint <- decode.field(1, decode.string)
    use target_region <- decode.field(2, decode.string)
    use target <- decode.field(3, decode.optional(decode.int))
    decode.success(#(direction, hint, target_region, target))
  }
  sqlight.query(
    "select direction, hint, target_region, target_id from exits where room_id = ?",
    store,
    [sqlight.int(room_id)],
    decoder,
  )
  |> result.unwrap([])
  |> list.filter_map(fn(row) {
    use direction <- result.map(types.parse_direction(row.0))
    Exit(direction:, hint: row.1, target_region: row.2, target: row.3)
  })
}

pub type NewExit {
  NewExit(
    direction: Direction,
    hint: String,
    target_region: String,
    target: Option(Int),
  )
}

/// Write a new room at `cell` with its exits and items, returning its id.
/// `Error(Nil)` if another room already holds that cell (two builds raced
/// for it): nothing is written, and the caller should use that room.
pub fn insert_room(
  store: Store,
  region: String,
  name: String,
  description: String,
  features: List(String),
  items: List(String),
  new_exits: List(NewExit),
  cell: types.Cell,
) -> Result(Int, Nil) {
  let #(x, y, z) = cell
  use id <- result.try(
    case
      sqlight.query(
        "insert into rooms (region_id, name, description, features, x, y, z) values (?, ?, ?, ?, ?, ?, ?) returning id",
        store,
        [
          sqlight.text(region),
          sqlight.text(name),
          sqlight.text(description),
          sqlight.text(string.join(features, "\n")),
          sqlight.int(x),
          sqlight.int(y),
          sqlight.int(z),
        ],
        decode.field(0, decode.int, decode.success),
      )
    {
      Ok([id]) -> Ok(id)
      _ -> Error(Nil)
    },
  )
  list.each(new_exits, fn(e) {
    let assert Ok(_) =
      sqlight.query(
        "insert into exits (room_id, direction, hint, target_region, target_id) values (?, ?, ?, ?, ?)",
        store,
        [
          sqlight.int(id),
          sqlight.text(types.direction_name(e.direction)),
          sqlight.text(e.hint),
          sqlight.text(e.target_region),
          sqlight.nullable(sqlight.int, e.target),
        ],
        decode.success(Nil),
      )
    Nil
  })
  list.each(items, fn(item) {
    let assert Ok(_) =
      sqlight.query(
        "insert into items (name, room_id) values (?, ?)",
        store,
        [sqlight.text(item), sqlight.int(id)],
        decode.success(Nil),
      )
    Nil
  })
  Ok(id)
}

/// Point an unbuilt exit at the room built for it. Only fills an empty
/// exit, so a second writer can never re-point an existing link.
pub fn link_exit(store: Store, room_id: Int, d: Direction, target: Int) -> Nil {
  let assert Ok(_) =
    sqlight.query(
      "update exits set target_id = ? where room_id = ? and direction = ? and target_id is null",
      store,
      [
        sqlight.int(target),
        sqlight.int(room_id),
        sqlight.text(types.direction_name(d)),
      ],
      decode.success(Nil),
    )
  Nil
}

pub fn art_url(store: Store, room_id: Int) -> Option(String) {
  case
    sqlight.query(
      "select art_url from rooms where id = ?",
      store,
      [sqlight.int(room_id)],
      decode.field(0, decode.optional(decode.string), decode.success),
    )
  {
    Ok([url]) -> url
    _ -> None
  }
}

pub fn set_art(store: Store, room_id: Int, url: String) -> Nil {
  let assert Ok(_) =
    sqlight.query(
      "update rooms set art_url = ? where id = ?",
      store,
      [sqlight.text(url), sqlight.int(room_id)],
      decode.success(Nil),
    )
  Nil
}

/// Every room name in the world, lowercased, for the builder's uniqueness
/// check.
pub fn room_names(store: Store) -> List(String) {
  sqlight.query(
    "select lower(name) from rooms",
    store,
    [],
    decode.field(0, decode.string, decode.success),
  )
  |> result.unwrap([])
}

/// Names of a few rooms near this one, for the builder's context.
pub fn neighbour_names(store: Store, room_id: Int) -> List(String) {
  sqlight.query(
    "select r.name from exits e join rooms r on r.id = e.target_id where e.room_id = ?",
    store,
    [sqlight.int(room_id)],
    decode.field(0, decode.string, decode.success),
  )
  |> result.unwrap([])
}

// ITEMS -----------------------------------------------------------------------

pub fn room_items(store: Store, room_id: Int) -> List(String) {
  sqlight.query(
    "select name from items where room_id = ? order by id",
    store,
    [sqlight.int(room_id)],
    decode.field(0, decode.string, decode.success),
  )
  |> result.unwrap([])
}

pub fn inventory(store: Store, player: String) -> List(String) {
  sqlight.query(
    "select name from items where holder = ? order by id",
    store,
    [sqlight.text(player)],
    decode.field(0, decode.string, decode.success),
  )
  |> result.unwrap([])
}

/// Move the first item in the room matching `query` to the player.
pub fn take_item(
  store: Store,
  room_id: Int,
  player: String,
  query: String,
) -> Result(String, Nil) {
  move_item(
    store,
    "select id, name from items where room_id = ?",
    [sqlight.int(room_id)],
    query,
    "update items set room_id = null, holder = ? where id = ?",
    sqlight.text(player),
  )
}

pub fn drop_item(
  store: Store,
  room_id: Int,
  player: String,
  query: String,
) -> Result(String, Nil) {
  move_item(
    store,
    "select id, name from items where holder = ?",
    [sqlight.text(player)],
    query,
    "update items set holder = null, room_id = ? where id = ?",
    sqlight.int(room_id),
  )
}

fn move_item(
  store: Store,
  find_sql: String,
  find_args: List(sqlight.Value),
  query: String,
  move_sql: String,
  destination: sqlight.Value,
) -> Result(String, Nil) {
  let decoder = {
    use id <- decode.field(0, decode.int)
    use name <- decode.field(1, decode.string)
    decode.success(#(id, name))
  }
  let candidates =
    sqlight.query(find_sql, store, find_args, decoder) |> result.unwrap([])
  use #(id, name) <- result.try(best_match(candidates, query))
  let assert Ok(_) =
    sqlight.query(
      move_sql,
      store,
      [destination, sqlight.int(id)],
      decode.success(Nil),
    )
  Ok(name)
}

/// Exact name first, then any item whose name contains every word asked for.
fn best_match(
  candidates: List(#(Int, String)),
  query: String,
) -> Result(#(Int, String), Nil) {
  let q = string.lowercase(string.trim(query))
  let words = string.split(q, " ") |> list.filter(fn(w) { w != "" })
  case list.find(candidates, fn(c) { string.lowercase(c.1) == q }) {
    Ok(found) -> Ok(found)
    Error(Nil) ->
      list.find(candidates, fn(c) {
        let name = string.lowercase(c.1)
        words != [] && list.all(words, string.contains(name, _))
      })
  }
}

// PLAYERS ---------------------------------------------------------------------

pub fn player_room(store: Store, name: String) -> Option(Int) {
  case
    sqlight.query(
      "select room_id from players where name = ?",
      store,
      [sqlight.text(name)],
      decode.field(0, decode.int, decode.success),
    )
  {
    Ok([id]) -> Some(id)
    _ -> None
  }
}

/// Remember that this player has been here (for their map).
pub fn record_visit(store: Store, name: String, room_id: Int) -> Nil {
  let assert Ok(_) =
    sqlight.query(
      "insert or ignore into visits (player, room_id) values (?, ?)",
      store,
      [sqlight.text(name), sqlight.int(room_id)],
      decode.success(Nil),
    )
  Nil
}

pub fn visited(store: Store, name: String) -> List(Int) {
  sqlight.query(
    "select room_id from visits where player = ? order by room_id",
    store,
    [sqlight.text(name)],
    decode.field(0, decode.int, decode.success),
  )
  |> result.unwrap([])
}

pub fn set_player_room(store: Store, name: String, room_id: Int) -> Nil {
  let assert Ok(_) =
    sqlight.query(
      "insert into players (name, room_id) values (?, ?) on conflict(name) do update set room_id = excluded.room_id",
      store,
      [sqlight.text(name), sqlight.int(room_id)],
      decode.success(Nil),
    )
  Nil
}

fn split_lines(text: String) -> List(String) {
  string.split(text, "\n") |> list.filter(fn(s) { string.trim(s) != "" })
}
