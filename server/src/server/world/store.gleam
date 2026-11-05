//// SQLite persistence: the single source of truth for the world. A room,
//// once written, is never regenerated — later visitors read the same rows.

import gleam/dynamic/decode
import gleam/int
import gleam/json
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
    #("exits", "lock_id", "text"),
    #("exits", "lock_desc", "text"),
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
    delete from pending_items; delete from closeups; delete from room_debug; delete from visits; delete from items; delete from players; delete from exits;
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
    decode.success(#(
      region,
      name,
      description,
      features,
      art_url,
      #(x, y, z),
      option.unwrap(picture, ""),
    ))
  }
  use row <- result.try(
    case
      sqlight.query(
        "select region_id, name, description, features, art_url, x, y, z, picture from rooms where id = ?",
        store,
        [sqlight.int(id)],
        decoder,
      )
    {
      Ok([row]) -> Ok(row)
      _ -> Error(Nil)
    },
  )
  let #(region, name, description, features, art_url, #(x, y, z), picture) = row
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
    decode.success(#(direction, hint, target_region, target, lock))
  }
  sqlight.query(
    "select direction, hint, target_region, target_id, lock_desc from exits where room_id = ?",
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
      lock: row.4,
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
    decode.success(
      Examinable(key: "item-" <> int.to_string(id), name:, looks: case looks {
        "" -> name
        _ -> looks
      }),
    )
  }
  sqlight.query(
    "select id, name, looks from items where (room_id = ? or holder = ?) and "
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
      "update exits set lock_id = ?, lock_desc = ? where room_id = ? and direction = ?",
      store,
      [
        sqlight.text(lock_id),
        sqlight.text(desc),
        sqlight.int(room_id),
        sqlight.text(types.direction_name(d)),
      ],
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
      "select lock_id, lock_desc from exits where room_id = ? and direction = ? and lock_id is not null",
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
              "update exits set lock_id = null, lock_desc = null where lock_id = ?",
              store,
              [sqlight.text(lock_id)],
              decode.success(Nil),
            )
          Unlocked(key: key_name, lock: desc)
        }
        _ -> Barred(desc)
      }
    _ -> Open
  }
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
