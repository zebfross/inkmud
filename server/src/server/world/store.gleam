//// SQLite persistence: the single source of truth for the world. A room,
//// once written, is never regenerated — later visitors read the same rows.

import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import server/world/danger
import server/world/types.{
  type Direction, type Exit, type Region, type Room, Exit, Region, Room,
}
import sqlight.{type Connection}

pub type Store =
  Connection

/// What stands in a passage between two cells (a lock, an obstacle) belongs
/// to the passage, not to either side of it: it bars the way both ways,
/// and opening it opens it from both sides. A door (between a street and a
/// building) is the passage's too. A passage is keyed by the cell
/// at its lower end along its axis (the north, west or lower cell) and the
/// axis ("ns", "ew" or "ud"). `exit_passages` gives each exit its
/// passage's lock and obstacle.
///
/// Worlds from before this kept locks and obstacles on the exits; they're
/// moved here once, on opening.
const passages_schema = "
create table if not exists passages (
  x integer not null,
  y integer not null,
  z integer not null,
  axis text not null,
  lock_id text,
  lock_desc text,
  obstacle_kind text,
  obstacle_desc text,
  door integer not null default 0,
  primary key (x, y, z, axis)
);
insert into passages (x, y, z, axis, lock_id, lock_desc)
select r.x - (e.direction = 'west'), r.y - (e.direction = 'north'),
       r.z - (e.direction = 'down'),
       case when e.direction in ('north', 'south') then 'ns'
            when e.direction in ('east', 'west') then 'ew' else 'ud' end,
       e.lock_id, e.lock_desc
from exits e join rooms r on r.id = e.room_id
where e.lock_id is not null and r.x is not null
on conflict do update set lock_id = excluded.lock_id, lock_desc = excluded.lock_desc;
insert into passages (x, y, z, axis, obstacle_kind, obstacle_desc)
select r.x - (e.direction = 'west'), r.y - (e.direction = 'north'),
       r.z - (e.direction = 'down'),
       case when e.direction in ('north', 'south') then 'ns'
            when e.direction in ('east', 'west') then 'ew' else 'ud' end,
       e.obstacle_kind, e.obstacle_desc
from exits e join rooms r on r.id = e.room_id
where e.obstacle_kind is not null and r.x is not null
on conflict do update set obstacle_kind = excluded.obstacle_kind,
  obstacle_desc = excluded.obstacle_desc;
update exits set lock_id = null, lock_desc = null, obstacle_kind = null,
  obstacle_desc = null
where lock_id is not null or obstacle_kind is not null;
"

const passages_view = "
drop view if exists exit_passages;
create view exit_passages as
select e.room_id, e.direction, e.hint, e.target_region, e.target_id,
       p.lock_id, p.lock_desc, p.obstacle_kind, p.obstacle_desc,
       coalesce(p.door, 0) as door
from exits e
join rooms r on r.id = e.room_id
left join passages p
  on p.x = r.x - (e.direction = 'west')
 and p.y = r.y - (e.direction = 'north')
 and p.z = r.z - (e.direction = 'down')
 and p.axis = case when e.direction in ('north', 'south') then 'ns'
                   when e.direction in ('east', 'west') then 'ew'
                   else 'ud' end;
"

/// The passage through `room_id`'s way `d`, as its key: #(x, y, z, axis).
fn passage(store: Store, room_id: Int, d: Direction) -> List(sqlight.Value) {
  let #(x, y, z) = case
    sqlight.query(
      "select x, y, z from rooms where id = ?",
      store,
      [sqlight.int(room_id)],
      {
        use x <- decode.field(0, decode.int)
        use y <- decode.field(1, decode.int)
        use z <- decode.field(2, decode.int)
        decode.success(#(x, y, z))
      },
    )
  {
    Ok([cell]) -> cell
    _ -> #(0, 0, 0)
  }
  let #(x, y, z) = case d {
    types.North | types.West | types.Down -> types.step(#(x, y, z), d)
    _ -> #(x, y, z)
  }
  let axis = case d {
    types.North | types.South -> "ns"
    types.East | types.West -> "ew"
    types.Up | types.Down -> "ud"
  }
  [sqlight.int(x), sqlight.int(y), sqlight.int(z), sqlight.text(axis)]
}

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
create table if not exists caches (
  x integer not null,
  y integer not null,
  z integer not null,
  name text not null,
  looks text not null,
  found integer not null default 0
);
create table if not exists map_marks (
  player text not null,
  x integer not null,
  y integer not null,
  z integer not null,
  primary key (player, x, y, z)
);
create table if not exists pending_items (
  x integer not null,
  y integer not null,
  z integer not null,
  name text not null,
  looks text not null,
  role text not null,
  unlocks text
);
create table if not exists closeups (
  key text primary key,
  url text not null,
  prompt text not null
);
create table if not exists feedback (
  id integer primary key,
  at text not null default (datetime('now')),
  player text not null,
  room_id integer,
  room_name text not null default '',
  text text not null,
  context text not null default ''
);
create table if not exists room_debug (
  room_id integer primary key references rooms(id),
  builder_prompt text not null default '',
  attempts text not null default '[]',
  image_prompt text,
  image_seed integer
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
  [
    #("rooms", "x", "integer"),
    #("rooms", "y", "integer"),
    #("rooms", "z", "integer"),
    #("rooms", "picture", "text"),
    #("items", "looks", "text not null default ''"),
    // What an item is for. Only items with a role can be picked up.
    // Existing items predate roles: treat them as valuables.
    #("items", "role", "text not null default 'valuable'"),
    // A key: the lock it opens.
    #("items", "unlocks", "text"),
    // A locked exit: its lock's id (matched by a key's `unlocks`) and what
    // the lock looks like.
    #("rooms", "dark", "integer not null default 0"),
    // A light's remaining oil.
    #("items", "charge", "integer not null default 0"),
    #("exits", "lock_id", "text"),
    #("exits", "lock_desc", "text"),
    // Blocked by an obstacle a tool of `obstacle_kind` gets you past.
    #("exits", "obstacle_kind", "text"),
    #("exits", "obstacle_desc", "text"),
    // Wounds taken, and when the next one heals (seconds since 1970; 0
    // when unhurt).
    #("players", "wounds", "integer not null default 0"),
    #("players", "heal_at", "integer not null default 0"),
    // Outdoors, inside or below (see `types.Setting`), and for an inside
    // place, its building.
    #("rooms", "setting", "text"),
    #("rooms", "building", "integer"),
  ]
  |> list.each(fn(column) {
    let #(table, name, kind) = column
    case has_column(conn, table, name) {
      True -> Nil
      False -> {
        let assert Ok(Nil) =
          sqlight.exec(
            "alter table "
              <> table
              <> " add column "
              <> name
              <> " "
              <> kind
              <> ";",
            conn,
          )
        Nil
      }
    }
  })
  let assert Ok(Nil) = sqlight.exec(passages_schema, conn)
  case has_column(conn, "passages", "door") {
    True -> Nil
    False -> {
      let assert Ok(Nil) =
        sqlight.exec(
          "alter table passages add column door integer not null default 0;",
          conn,
        )
      Nil
    }
  }
  let assert Ok(Nil) = sqlight.exec(passages_view, conn)
  // Places from before settings: underground is below, the rest outdoors.
  let assert Ok(Nil) =
    sqlight.exec(
      "update rooms set setting = case when z < 0 then 'below' else 'outdoors' end where setting is null;",
      conn,
    )
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
    delete from caches; delete from map_marks;
    delete from pending_items; delete from closeups; delete from room_debug; delete from visits; delete from items; delete from players; delete from exits; delete from passages;
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
    use picture <- decode.field(8, decode.optional(decode.string))
    use dark <- decode.field(9, decode.int)
    use setting <- decode.field(10, decode.optional(decode.string))
    use building <- decode.field(11, decode.optional(decode.int))
    decode.success(#(
      region,
      name,
      description,
      features,
      art_url,
      #(x, y, z),
      #(option.unwrap(picture, ""), dark == 1, setting, building),
    ))
  }
  use row <- result.try(
    case
      sqlight.query(
        "select region_id, name, description, features, art_url, x, y, z, picture, dark, setting, building from rooms where id = ?",
        store,
        [sqlight.int(id)],
        decoder,
      )
    {
      Ok([row]) -> Ok(row)
      _ -> Error(Nil)
    },
  )
  let #(
    region,
    name,
    description,
    features,
    art_url,
    #(x, y, z),
    #(picture, dark, setting, building),
  ) = row
  Ok(Room(
    id:,
    region:,
    name:,
    description:,
    features: split_lines(features),
    items: room_items(store, id),
    exits: exits(store, id),
    art_url:,
    picture:,
    // Only rooms from before coordinates existed lack them, and those are
    // placed at startup before anyone plays.
    x: option.unwrap(x, 0),
    y: option.unwrap(y, 0),
    z: option.unwrap(z, 0),
    dark:,
    setting: case setting {
      Some(text) -> types.parse_setting(text)
      None ->
        case option.unwrap(z, 0) < 0 {
          True -> types.Below
          False -> types.Outdoors
        }
    },
    building:,
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
    use lock <- decode.field(4, decode.optional(decode.string))
    use obstacle_kind <- decode.field(5, decode.optional(decode.string))
    use obstacle_desc <- decode.field(6, decode.optional(decode.string))
    use door <- decode.field(7, decode.int)
    let obstacle = case obstacle_kind, obstacle_desc {
      Some(kind), Some(desc) -> Some(types.Obstacle(kind:, desc:))
      _, _ -> None
    }
    decode.success(#(
      direction,
      hint,
      target_region,
      target,
      #(lock, obstacle, door == 1),
    ))
  }
  sqlight.query(
    "select direction, hint, target_region, target_id, lock_desc, obstacle_kind, obstacle_desc, door from exit_passages where room_id = ?",
    store,
    [sqlight.int(room_id)],
    decoder,
  )
  |> result.unwrap([])
  |> list.filter_map(fn(row) {
    use direction <- result.map(types.parse_direction(row.0))
    Exit(
      direction:,
      hint: row.1,
      target_region: row.2,
      target: row.3,
      lock: row.4.0,
      obstacle: row.4.1,
      door: row.4.2,
    )
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

pub fn set_picture(store: Store, room_id: Int, picture: String) -> Nil {
  let assert Ok(_) =
    sqlight.query(
      "update rooms set picture = ? where id = ?",
      store,
      [sqlight.text(picture), sqlight.int(room_id)],
      decode.success(Nil),
    )
  Nil
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
    "select name from items where room_id = ? and "
      <> takeable()
      <> " order by id",
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
    "select id, name from items where room_id = ? and " <> takeable(),
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

// WOUNDS ----------------------------------------------------------------------

/// How hurt a player is now: wounds heal one at a time, every
/// `danger.heal_seconds`, whether or not they're playing.
pub fn wounds(store: Store, player: String) -> Int {
  let decoder = {
    use wounds <- decode.field(0, decode.int)
    use heal_at <- decode.field(1, decode.int)
    decode.success(#(wounds, heal_at))
  }
  case
    sqlight.query(
      "select wounds, heal_at from players where name = ?",
      store,
      [sqlight.text(player)],
      decoder,
    )
  {
    Ok([#(0, _)]) | Ok([]) | Error(_) -> 0
    Ok([#(wounds, heal_at), ..]) -> {
      let now = danger.now()
      case now >= heal_at {
        False -> wounds
        True -> {
          let healed = 1 + { now - heal_at } / danger.heal_seconds
          let left = int.max(0, wounds - healed)
          write_wounds(
            store,
            player,
            left,
            heal_at + healed * danger.heal_seconds,
          )
          left
        }
      }
    }
  }
}

/// One more wound; returns how many the player now has.
pub fn add_wound(store: Store, player: String) -> Int {
  let wounds = wounds(store, player) + 1
  let heal_at = case wounds {
    // The first wound starts the healing clock; later ones queue behind it.
    1 -> danger.now() + danger.heal_seconds
    _ -> current_heal_at(store, player)
  }
  write_wounds(store, player, wounds, heal_at)
  wounds
}

/// Set wounds outright (rested: 0; woken after collapsing: 1).
pub fn set_wounds(store: Store, player: String, wounds: Int) -> Nil {
  write_wounds(store, player, wounds, danger.now() + danger.heal_seconds)
}

fn current_heal_at(store: Store, player: String) -> Int {
  case
    sqlight.query(
      "select heal_at from players where name = ?",
      store,
      [sqlight.text(player)],
      decode.field(0, decode.int, decode.success),
    )
  {
    Ok([at]) -> at
    _ -> danger.now() + danger.heal_seconds
  }
}

fn write_wounds(
  store: Store,
  player: String,
  wounds: Int,
  heal_at: Int,
) -> Nil {
  let heal_at = case wounds {
    0 -> 0
    _ -> heal_at
  }
  let assert Ok(_) =
    sqlight.query(
      "update players set wounds = ?, heal_at = ? where name = ?",
      store,
      [sqlight.int(wounds), sqlight.int(heal_at), sqlight.text(player)],
      decode.success(Nil),
    )
  Nil
}

/// Everything a player carries, left lying where they fell. Returns what
/// was dropped.
pub fn drop_all(store: Store, room_id: Int, player: String) -> List(String) {
  let names =
    sqlight.query(
      "select name from items where holder = ? order by id",
      store,
      [sqlight.text(player)],
      decode.field(0, decode.string, decode.success),
    )
    |> result.unwrap([])
  let assert Ok(_) =
    sqlight.query(
      "update items set holder = null, room_id = ? where holder = ?",
      store,
      [sqlight.int(room_id), sqlight.text(player)],
      decode.success(Nil),
    )
  names
}

/// The tools a player carries, as (name, kind).
pub fn carried_tools(store: Store, player: String) -> List(#(String, String)) {
  carried_item_rows(store, player)
  |> list.filter_map(fn(row) {
    case row.role, row.unlocks {
      "tool", Some(kind) -> Ok(#(row.name, kind))
      _, _ -> Error(Nil)
    }
  })
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

// DEBUG (developer view of how a room was made) ------------------------------

/// One reply from the room builder: the feedback it was sent with (empty
/// for the first try), what the model replied, and why it was rejected
/// (empty if it was the one used).
pub type BuildAttempt {
  BuildAttempt(feedback: String, reply: String, problem: String)
}

pub type RoomDebug {
  RoomDebug(
    builder_prompt: String,
    attempts: List(BuildAttempt),
    image_prompt: Option(String),
    image_seed: Option(Int),
  )
}

pub fn save_build_debug(
  store: Store,
  room_id: Int,
  prompt: String,
  attempts: List(BuildAttempt),
) -> Nil {
  let attempts_json =
    json.array(attempts, fn(a) {
      json.object([
        #("feedback", json.string(a.feedback)),
        #("reply", json.string(a.reply)),
        #("problem", json.string(a.problem)),
      ])
    })
    |> json.to_string
  let assert Ok(_) =
    sqlight.query(
      "insert into room_debug (room_id, builder_prompt, attempts) values (?, ?, ?)
       on conflict(room_id) do update set builder_prompt = excluded.builder_prompt, attempts = excluded.attempts",
      store,
      [sqlight.int(room_id), sqlight.text(prompt), sqlight.text(attempts_json)],
      decode.success(Nil),
    )
  Nil
}

/// A player's note about something that felt off. Kept across world resets
/// (it's about the game, not this world).
pub fn add_feedback(
  store: Store,
  player: String,
  room_id: Int,
  room_name: String,
  text: String,
  context: String,
) -> Nil {
  let assert Ok(_) =
    sqlight.query(
      "insert into feedback (player, room_id, room_name, text, context) values (?, ?, ?, ?, ?)",
      store,
      [
        sqlight.text(player),
        sqlight.int(room_id),
        sqlight.text(room_name),
        sqlight.text(text),
        sqlight.text(context),
      ],
      decode.success(Nil),
    )
  Nil
}

pub fn save_image_debug(
  store: Store,
  room_id: Int,
  prompt: String,
  seed: Int,
) -> Nil {
  let assert Ok(_) =
    sqlight.query(
      "insert into room_debug (room_id, image_prompt, image_seed) values (?, ?, ?)
       on conflict(room_id) do update set image_prompt = excluded.image_prompt, image_seed = excluded.image_seed",
      store,
      [sqlight.int(room_id), sqlight.text(prompt), sqlight.int(seed)],
      decode.success(Nil),
    )
  Nil
}

pub fn load_debug(store: Store, room_id: Int) -> RoomDebug {
  let attempt = {
    use feedback <- decode.field("feedback", decode.string)
    use reply <- decode.field("reply", decode.string)
    use problem <- decode.field("problem", decode.string)
    decode.success(BuildAttempt(feedback:, reply:, problem:))
  }
  let row = {
    use builder_prompt <- decode.field(0, decode.string)
    use attempts <- decode.field(1, decode.string)
    use image_prompt <- decode.field(2, decode.optional(decode.string))
    use image_seed <- decode.field(3, decode.optional(decode.int))
    decode.success(RoomDebug(
      builder_prompt:,
      attempts: json.parse(attempts, decode.list(attempt)) |> result.unwrap([]),
      image_prompt:,
      image_seed:,
    ))
  }
  case
    sqlight.query(
      "select builder_prompt, attempts, image_prompt, image_seed from room_debug where room_id = ?",
      store,
      [sqlight.int(room_id)],
      row,
    )
  {
    Ok([debug]) -> debug
    _ -> RoomDebug("", [], None, None)
  }
}

// CLOSE-UPS (examine draws the thing itself) ----------------------------------

/// Something that can be examined up close: an item (in a room or carried)
/// or one of a room's visual details.
pub type Examinable {
  Examinable(
    /// Stable key for its saved close-up: "item-<id>" follows an item
    /// wherever it's carried; "detail-<room>-<n>" stays with the room.
    key: String,
    name: String,
    /// Plain physical description for the image model.
    looks: String,
    /// A treasure map: the cell it leads to.
    leads_to: Option(types.Cell),
  )
}

/// Record what an item plainly looks like (from the room builder).
pub fn set_item_look(
  store: Store,
  room_id: Int,
  name: String,
  looks: String,
) -> Nil {
  let assert Ok(_) =
    sqlight.query(
      "update items set looks = ? where room_id = ? and name = ?",
      store,
      [sqlight.text(looks), sqlight.int(room_id), sqlight.text(name)],
      decode.success(Nil),
    )
  Nil
}

/// The items in a room and those a player carries, with their looks.
pub fn examinable_items(
  store: Store,
  room_id: Int,
  player: String,
) -> List(Examinable) {
  let row = {
    use id <- decode.field(0, decode.int)
    use name <- decode.field(1, decode.string)
    use looks <- decode.field(2, decode.string)
    use unlocks <- decode.field(3, decode.optional(decode.string))
    decode.success(
      Examinable(
        key: "item-" <> int.to_string(id),
        name:,
        looks: case looks {
          "" -> name
          _ -> looks
        },
        leads_to: case unlocks {
          Some(code) -> map_target(code) |> option.from_result
          None -> None
        },
      ),
    )
  }
  sqlight.query(
    "select id, name, looks, unlocks from items where (room_id = ? or holder = ?) and "
      <> takeable()
      <> " order by holder is null desc, id",
    store,
    [sqlight.int(room_id), sqlight.text(player)],
    row,
  )
  |> result.unwrap([])
}

pub fn closeup_url(store: Store, key: String) -> Option(String) {
  case
    sqlight.query(
      "select url from closeups where key = ?",
      store,
      [sqlight.text(key)],
      decode.field(0, decode.string, decode.success),
    )
  {
    Ok([url]) -> Some(url)
    _ -> None
  }
}

pub fn set_closeup(
  store: Store,
  key: String,
  url: String,
  prompt: String,
) -> Nil {
  let assert Ok(_) =
    sqlight.query(
      "insert or replace into closeups (key, url, prompt) values (?, ?, ?)",
      store,
      [sqlight.text(key), sqlight.text(url), sqlight.text(prompt)],
      decode.success(Nil),
    )
  Nil
}

// LOCKS AND KEYS --------------------------------------------------------------

/// What happens when a player tries an exit.
pub type Passage {
  Open
  /// Locked, and they don't carry its key: what bars the way.
  Barred(lock: String)
  /// They carried the key: it's left in the lock, which is now open for
  /// everyone. The key's name and the lock's description, for the telling.
  Unlocked(key: String, lock: String)
  /// An obstacle, and they carry no tool of its kind.
  Obstructed(obstacle: types.Obstacle)
  /// They carried a tool of the obstacle's kind: it's cleared for everyone
  /// (the tool is kept).
  Cleared(tool: String, obstacle: types.Obstacle)
}

/// Lock an exit (when its room is built). `lock_id` is what its key opens.
pub fn lock_exit(
  store: Store,
  room_id: Int,
  d: types.Direction,
  lock_id: String,
  desc: String,
) -> Nil {
  let assert Ok(_) =
    sqlight.query(
      "insert into passages (lock_id, lock_desc, x, y, z, axis) values (?, ?, ?, ?, ?, ?)
       on conflict do update set lock_id = excluded.lock_id, lock_desc = excluded.lock_desc",
      store,
      [sqlight.text(lock_id), sqlight.text(desc), ..passage(store, room_id, d)],
      decode.success(Nil),
    )
  Nil
}

/// Try to go through an exit: open, barred, or opened now with a key the
/// player carries (the key is used up and the lock cleared, for good).
pub fn pass(
  store: Store,
  player: String,
  room_id: Int,
  d: types.Direction,
) -> Passage {
  let lock =
    sqlight.query(
      "select lock_id, lock_desc from exit_passages where room_id = ? and direction = ? and lock_id is not null",
      store,
      [sqlight.int(room_id), sqlight.text(types.direction_name(d))],
      {
        use id <- decode.field(0, decode.string)
        use desc <- decode.field(1, decode.optional(decode.string))
        decode.success(#(id, option.unwrap(desc, "something")))
      },
    )
  case lock {
    Ok([#(lock_id, desc)]) ->
      case
        sqlight.query(
          "select id, name from items where holder = ? and unlocks = ? limit 1",
          store,
          [sqlight.text(player), sqlight.text(lock_id)],
          {
            use id <- decode.field(0, decode.int)
            use name <- decode.field(1, decode.string)
            decode.success(#(id, name))
          },
        )
      {
        Ok([#(key_id, key_name)]) -> {
          let assert Ok(_) =
            sqlight.query(
              "delete from items where id = ?",
              store,
              [sqlight.int(key_id)],
              decode.success(Nil),
            )
          let assert Ok(_) =
            sqlight.query(
              "update passages set lock_id = null, lock_desc = null where lock_id = ?",
              store,
              [sqlight.text(lock_id)],
              decode.success(Nil),
            )
          Unlocked(key: key_name, lock: desc)
        }
        _ -> Barred(desc)
      }
    _ -> past_obstacle(store, player, room_id, d)
  }
}

/// No lock (or it was opened): is there an obstacle, and can they clear it?
fn past_obstacle(
  store: Store,
  player: String,
  room_id: Int,
  d: types.Direction,
) -> Passage {
  let obstacle =
    sqlight.query(
      "select obstacle_kind, obstacle_desc from exit_passages where room_id = ? and direction = ? and obstacle_kind is not null",
      store,
      [sqlight.int(room_id), sqlight.text(types.direction_name(d))],
      {
        use kind <- decode.field(0, decode.string)
        use desc <- decode.field(1, decode.optional(decode.string))
        decode.success(types.Obstacle(
          kind:,
          desc: option.unwrap(desc, "something"),
        ))
      },
    )
  case obstacle {
    Ok([o]) ->
      case
        sqlight.query(
          "select name from items where holder = ? and role = 'tool' and unlocks = ? limit 1",
          store,
          [sqlight.text(player), sqlight.text(o.kind)],
          decode.field(0, decode.string, decode.success),
        )
      {
        Ok([tool]) -> {
          let assert Ok(_) =
            sqlight.query(
              "update passages set obstacle_kind = null, obstacle_desc = null where x = ? and y = ? and z = ? and axis = ?",
              store,
              passage(store, room_id, d),
              decode.success(Nil),
            )
          Cleared(tool:, obstacle: o)
        }
        _ -> Obstructed(o)
      }
    _ -> Open
  }
}

/// Block an exit with an obstacle of a tool kind.
pub fn set_obstacle(
  store: Store,
  room_id: Int,
  d: types.Direction,
  obstacle: types.Obstacle,
) -> Nil {
  let assert Ok(_) =
    sqlight.query(
      "insert into passages (obstacle_kind, obstacle_desc, x, y, z, axis) values (?, ?, ?, ?, ?, ?)
       on conflict do update set obstacle_kind = excluded.obstacle_kind, obstacle_desc = excluded.obstacle_desc",
      store,
      [
        sqlight.text(obstacle.kind),
        sqlight.text(obstacle.desc),
        ..passage(store, room_id, d)
      ],
      decode.success(Nil),
    )
  Nil
}

/// Tools of a kind nobody is carrying: lying in a room, or promised.
pub fn free_tools(store: Store, kind: String) -> Int {
  let count = fn(sql) {
    case
      sqlight.query(
        sql,
        store,
        [sqlight.text(kind)],
        decode.field(0, decode.int, decode.success),
      )
    {
      Ok([n]) -> n
      _ -> 0
    }
  }
  count(
    "select count(*) from items where role = 'tool' and unlocks = ? and room_id is not null",
  )
  + count(
    "select count(*) from pending_items where role = 'tool' and unlocks = ?",
  )
}

/// Give items a role (and a key the lock it opens), after the room is
/// written.
pub fn set_item_role(
  store: Store,
  room_id: Int,
  name: String,
  role: String,
  unlocks: Option(String),
) -> Nil {
  let assert Ok(_) =
    sqlight.query(
      "update items set role = ?, unlocks = ? where room_id = ? and name = ?",
      store,
      [
        sqlight.text(role),
        sqlight.nullable(sqlight.text, unlocks),
        sqlight.int(room_id),
        sqlight.text(name),
      ],
      decode.success(Nil),
    )
  Nil
}

/// An item promised to whatever room gets built at a grid cell: a key for a
/// lock nearby, placed where it can be reached without that lock.
pub type Pending {
  Pending(name: String, looks: String, role: String, unlocks: Option(String))
}

pub fn add_pending(store: Store, cell: types.Cell, item: Pending) -> Nil {
  let #(x, y, z) = cell
  let assert Ok(_) =
    sqlight.query(
      "insert into pending_items (x, y, z, name, looks, role, unlocks) values (?, ?, ?, ?, ?, ?, ?)",
      store,
      [
        sqlight.int(x),
        sqlight.int(y),
        sqlight.int(z),
        sqlight.text(item.name),
        sqlight.text(item.looks),
        sqlight.text(item.role),
        sqlight.nullable(sqlight.text, item.unlocks),
      ],
      decode.success(Nil),
    )
  Nil
}

/// Items promised to a cell (without removing them).
pub fn pending_at(store: Store, cell: types.Cell) -> List(Pending) {
  let #(x, y, z) = cell
  sqlight.query(
    "select name, looks, role, unlocks from pending_items where x = ? and y = ? and z = ?",
    store,
    [sqlight.int(x), sqlight.int(y), sqlight.int(z)],
    {
      use name <- decode.field(0, decode.string)
      use looks <- decode.field(1, decode.string)
      use role <- decode.field(2, decode.string)
      use unlocks <- decode.field(3, decode.optional(decode.string))
      decode.success(Pending(name:, looks:, role:, unlocks:))
    },
  )
  |> result.unwrap([])
}

/// The room at `cell` has been built with its promised items: forget them.
pub fn clear_pending(store: Store, cell: types.Cell) -> Nil {
  let #(x, y, z) = cell
  let assert Ok(_) =
    sqlight.query(
      "delete from pending_items where x = ? and y = ? and z = ?",
      store,
      [sqlight.int(x), sqlight.int(y), sqlight.int(z)],
      decode.success(Nil),
    )
  Nil
}

/// SQL condition: the item has a role the game uses (see
/// `types.takeable_roles`). Only those are shown, taken or examined.
fn takeable() -> String {
  "role in ("
  <> types.takeable_roles
  |> list.map(fn(r) { "'" <> r <> "'" })
  |> string.join(", ")
  <> ")"
}

// LIGHT AND DARK --------------------------------------------------------------

/// What kind of place a new room is, and for an inside one, its building.
pub fn set_setting(
  store: Store,
  room_id: Int,
  setting: types.Setting,
  building: Option(Int),
) -> Nil {
  let assert Ok(_) =
    sqlight.query(
      "update rooms set setting = ?, building = ? where id = ?",
      store,
      [
        sqlight.text(types.setting_name(setting)),
        sqlight.nullable(sqlight.int, building),
        sqlight.int(room_id),
      ],
      decode.success(Nil),
    )
  Nil
}

/// Make the passage through `room_id`'s way `d` a door (both sides see it).
pub fn set_door(store: Store, room_id: Int, d: Direction) -> Nil {
  let assert Ok(_) =
    sqlight.query(
      "insert into passages (door, x, y, z, axis) values (1, ?, ?, ?, ?)
       on conflict do update set door = 1",
      store,
      passage(store, room_id, d),
      decode.success(Nil),
    )
  Nil
}

/// A building's rooms: #(on the ground floor, upstairs).
pub fn building_rooms(store: Store, building: Int) -> #(Int, Int) {
  case
    sqlight.query(
      "select coalesce(sum(z = 0), 0), coalesce(sum(z > 0), 0) from rooms where building = ?",
      store,
      [sqlight.int(building)],
      {
        use ground <- decode.field(0, decode.int)
        use up <- decode.field(1, decode.int)
        decode.success(#(ground, up))
      },
    )
  {
    Ok([counts]) -> counts
    _ -> #(0, 0)
  }
}

/// A building's ways out still leading nowhere built: #(to more rooms on
/// its floor, up its stairs). Doors out don't count.
pub fn building_open_ways(store: Store, building: Int) -> #(Int, Int) {
  case
    sqlight.query(
      "select coalesce(sum(e.direction in ('north', 'south', 'east', 'west')), 0),
              coalesce(sum(e.direction = 'up'), 0)
       from exit_passages e join rooms r on r.id = e.room_id
       where r.building = ? and e.target_id is null and e.door = 0",
      store,
      [sqlight.int(building)],
      {
        use across <- decode.field(0, decode.int)
        use up <- decode.field(1, decode.int)
        decode.success(#(across, up))
      },
    )
  {
    Ok([counts]) -> counts
    _ -> #(0, 0)
  }
}

pub fn set_dark(store: Store, room_id: Int) -> Nil {
  let assert Ok(_) =
    sqlight.query(
      "update rooms set dark = 1 where id = ?",
      store,
      [sqlight.int(room_id)],
      decode.success(Nil),
    )
  Nil
}

/// Fill a newly placed light (or anything given a charge).
pub fn set_item_charge(
  store: Store,
  room_id: Int,
  name: String,
  charge: Int,
) -> Nil {
  let assert Ok(_) =
    sqlight.query(
      "update items set charge = ? where room_id = ? and name = ?",
      store,
      [sqlight.int(charge), sqlight.int(room_id), sqlight.text(name)],
      decode.success(Nil),
    )
  Nil
}

/// The best light a player carries (most oil): id, name, oil left.
pub fn carried_light(
  store: Store,
  player: String,
) -> Option(#(Int, String, Int)) {
  case
    sqlight.query(
      "select id, name, charge from items where holder = ? and role = 'light' order by charge desc limit 1",
      store,
      [sqlight.text(player)],
      {
        use id <- decode.field(0, decode.int)
        use name <- decode.field(1, decode.string)
        use charge <- decode.field(2, decode.int)
        decode.success(#(id, name, charge))
      },
    )
  {
    Ok([light]) -> Some(light)
    _ -> None
  }
}

/// Carrying a light that still has oil.
pub fn has_light(store: Store, player: String) -> Bool {
  case carried_light(store, player) {
    Some(#(_, _, charge)) -> charge > 0
    None -> False
  }
}

/// A step in the dark: the light burns one unit. Its name and what's left,
/// or `None` if the player has no lit light.
pub fn burn(store: Store, player: String) -> Option(#(String, Int)) {
  case carried_light(store, player) {
    Some(#(id, name, charge)) if charge > 0 -> {
      let left = charge - 1
      let assert Ok(_) =
        sqlight.query(
          "update items set charge = ? where id = ?",
          store,
          [sqlight.int(left), sqlight.int(id)],
          decode.success(Nil),
        )
      Some(#(name, left))
    }
    _ -> None
  }
}

/// Pour a carried fuel item into the emptiest carried light. The light's
/// name, the fuel's name and the oil now in the light.
pub fn refill(
  store: Store,
  player: String,
) -> Result(#(String, String, Int), String) {
  let lights =
    sqlight.query(
      "select id, name, charge from items where holder = ? and role = 'light' order by charge asc limit 1",
      store,
      [sqlight.text(player)],
      {
        use id <- decode.field(0, decode.int)
        use name <- decode.field(1, decode.string)
        use charge <- decode.field(2, decode.int)
        decode.success(#(id, name, charge))
      },
    )
  let fuels =
    sqlight.query(
      "select id, name from items where holder = ? and role = 'fuel' order by id limit 1",
      store,
      [sqlight.text(player)],
      {
        use id <- decode.field(0, decode.int)
        use name <- decode.field(1, decode.string)
        decode.success(#(id, name))
      },
    )
  case lights, fuels {
    Ok([]), _ | Error(_), _ -> Error("You have nothing to fill.")
    _, Ok([]) | _, Error(_) -> Error("You have no oil to fill it with.")
    Ok([#(light_id, light, charge), ..]), Ok([#(fuel_id, fuel), ..]) -> {
      let now = charge + types.lantern_oil
      let assert Ok(_) =
        sqlight.query(
          "update items set charge = ? where id = ?",
          store,
          [sqlight.int(now), sqlight.int(light_id)],
          decode.success(Nil),
        )
      let assert Ok(_) =
        sqlight.query(
          "delete from items where id = ?",
          store,
          [sqlight.int(fuel_id)],
          decode.success(Nil),
        )
      Ok(#(light, fuel, now))
    }
  }
}

/// Lights nobody is carrying: lying in a room, or promised to one.
pub fn free_lights(store: Store) -> Int {
  let count = fn(sql) {
    case
      sqlight.query(sql, store, [], decode.field(0, decode.int, decode.success))
    {
      Ok([n]) -> n
      _ -> 0
    }
  }
  count(
    "select count(*) from items where role = 'light' and room_id is not null",
  )
  + count("select count(*) from pending_items where role = 'light'")
}

/// Any lights in the world at all (so oil is worth finding).
pub fn any_lights(store: Store) -> Bool {
  case
    sqlight.query(
      "select (select count(*) from items where role = 'light') + (select count(*) from pending_items where role = 'light')",
      store,
      [],
      decode.field(0, decode.int, decode.success),
    )
  {
    Ok([n]) -> n > 0
    _ -> False
  }
}

/// An unbuilt cell at street level next to a built street-level room,
/// through one of its open, unlocked ways out: somewhere a light can be
/// promised that anyone can reach without one. Nearest the centre first.
pub fn street_cell_for_light(store: Store) -> Option(types.Cell) {
  sqlight.query(
    "select r.x, r.y, r.z, e.direction from exit_passages e join rooms r on r.id = e.room_id
     where r.z = 0 and r.dark = 0 and e.target_id is null and e.lock_id is null
       and e.direction not in ('up', 'down')
     order by abs(r.x) + abs(r.y), r.id",
    store,
    [],
    {
      use x <- decode.field(0, decode.int)
      use y <- decode.field(1, decode.int)
      use z <- decode.field(2, decode.int)
      use d <- decode.field(3, decode.string)
      decode.success(#(#(x, y, z), d))
    },
  )
  |> result.unwrap([])
  |> list.filter_map(fn(row) {
    use d <- result.try(types.parse_direction(row.1))
    let cell = types.step(row.0, d)
    case room_at(store, cell) {
      None -> Ok(cell)
      Some(_) -> Error(Nil)
    }
  })
  |> list.first
  |> option.from_result
}

// TREASURE --------------------------------------------------------------------

/// Bury a treasure at a cell (built or not) for a map to lead to.
pub fn add_cache(
  store: Store,
  cell: types.Cell,
  treasure: types.Treasure,
) -> Nil {
  let #(x, y, z) = cell
  let assert Ok(_) =
    sqlight.query(
      "insert into caches (x, y, z, name, looks) values (?, ?, ?, ?, ?)",
      store,
      [
        sqlight.int(x),
        sqlight.int(y),
        sqlight.int(z),
        sqlight.text(treasure.name),
        sqlight.text(treasure.looks),
      ],
      decode.success(Nil),
    )
  Nil
}

pub type Dug {
  /// No spade (or crowbar) to dig with.
  NothingToDigWith
  /// Dug, found nothing.
  OnlyDirt
  /// Dug up a buried treasure: now carried.
  Unearthed(name: String)
}

/// Dig where the player stands.
pub fn dig(
  store: Store,
  player: String,
  room_id: Int,
  cell: types.Cell,
) -> Dug {
  let #(x, y, z) = cell
  let tool =
    sqlight.query(
      "select name from items where holder = ? and role = 'tool' and unlocks in ("
        <> types.digging_tools
      |> list.map(fn(k) { "'" <> k <> "'" })
      |> string.join(", ")
        <> ") limit 1",
      store,
      [sqlight.text(player)],
      decode.field(0, decode.string, decode.success),
    )
  case tool {
    Ok([_]) ->
      case
        sqlight.query(
          "select rowid, name, looks from caches where x = ? and y = ? and z = ? and found = 0 limit 1",
          store,
          [sqlight.int(x), sqlight.int(y), sqlight.int(z)],
          {
            use id <- decode.field(0, decode.int)
            use name <- decode.field(1, decode.string)
            use looks <- decode.field(2, decode.string)
            decode.success(#(id, name, looks))
          },
        )
      {
        Ok([#(id, name, looks)]) -> {
          let assert Ok(_) =
            sqlight.query(
              "update caches set found = 1 where rowid = ?",
              store,
              [sqlight.int(id)],
              decode.success(Nil),
            )
          let assert Ok(_) =
            sqlight.query(
              "insert into items (name, holder, role, looks) values (?, ?, 'treasure', ?)",
              store,
              [sqlight.text(name), sqlight.text(player), sqlight.text(looks)],
              decode.success(Nil),
            )
          let _ = room_id
          Unearthed(name)
        }
        _ -> OnlyDirt
      }
    _ -> NothingToDigWith
  }
}

/// A treasure map's cache: its cell, parsed from the map's `unlocks`
/// ("cache:x,y,z").
pub fn map_target(unlocks: String) -> Result(types.Cell, Nil) {
  case string.split(unlocks, ":") {
    ["cache", coords] ->
      case list.map(string.split(coords, ","), int.parse) {
        [Ok(x), Ok(y), Ok(z)] -> Ok(#(x, y, z))
        _ -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

pub fn map_code(cell: types.Cell) -> String {
  "cache:"
  <> int.to_string(cell.0)
  <> ","
  <> int.to_string(cell.1)
  <> ","
  <> int.to_string(cell.2)
}

/// Mark a treasure's place on a player's map (from reading its map).
pub fn add_mark(store: Store, player: String, cell: types.Cell) -> Nil {
  let #(x, y, z) = cell
  let assert Ok(_) =
    sqlight.query(
      "insert or ignore into map_marks (player, x, y, z) values (?, ?, ?, ?)",
      store,
      [sqlight.text(player), sqlight.int(x), sqlight.int(y), sqlight.int(z)],
      decode.success(Nil),
    )
  Nil
}

/// A player's marks for treasure not yet dug up.
pub fn marks(store: Store, player: String) -> List(types.Cell) {
  sqlight.query(
    "select m.x, m.y, m.z from map_marks m where m.player = ?
     and exists (select 1 from caches c where c.x = m.x and c.y = m.y and c.z = m.z and c.found = 0)",
    store,
    [sqlight.text(player)],
    {
      use x <- decode.field(0, decode.int)
      use y <- decode.field(1, decode.int)
      use z <- decode.field(2, decode.int)
      decode.success(#(x, y, z))
    },
  )
  |> result.unwrap([])
}

/// Unbuilt cells a player could reach by walking: beyond an open way out
/// (unlocked, unblocked) of a built room. Where a map's treasure can go.
pub fn reachable_unbuilt(store: Store) -> List(types.Cell) {
  sqlight.query(
    "select r.x, r.y, r.z, e.direction from exit_passages e join rooms r on r.id = e.room_id
     where e.target_id is null and e.lock_id is null and e.obstacle_kind is null",
    store,
    [],
    {
      use x <- decode.field(0, decode.int)
      use y <- decode.field(1, decode.int)
      use z <- decode.field(2, decode.int)
      use d <- decode.field(3, decode.string)
      decode.success(#(#(x, y, z), d))
    },
  )
  |> result.unwrap([])
  |> list.filter_map(fn(row) {
    use d <- result.try(types.parse_direction(row.1))
    let cell = types.step(row.0, d)
    case room_at(store, cell) {
      None -> Ok(cell)
      Some(_) -> Error(Nil)
    }
  })
  |> list.unique
}

// ITEM DETAILS (for the client's panels) -------------------------------------

/// An item as the client shows it: name, role, what a tool is for (or a
/// key's lock), and a light's oil.
pub type ItemRow {
  ItemRow(name: String, role: String, unlocks: Option(String), charge: Int)
}

fn item_rows(store: Store, where: String, arg: sqlight.Value) -> List(ItemRow) {
  sqlight.query(
    "select name, role, unlocks, charge from items where "
      <> where
      <> " and "
      <> takeable()
      <> " order by id",
    store,
    [arg],
    {
      use name <- decode.field(0, decode.string)
      use role <- decode.field(1, decode.string)
      use unlocks <- decode.field(2, decode.optional(decode.string))
      use charge <- decode.field(3, decode.int)
      decode.success(ItemRow(name:, role:, unlocks:, charge:))
    },
  )
  |> result.unwrap([])
}

pub fn room_item_rows(store: Store, room_id: Int) -> List(ItemRow) {
  item_rows(store, "room_id = ?", sqlight.int(room_id))
}

pub fn carried_item_rows(store: Store, player: String) -> List(ItemRow) {
  item_rows(store, "holder = ?", sqlight.text(player))
}
