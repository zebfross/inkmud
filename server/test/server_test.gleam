import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import server/art
import server/command.{
  Drop, Examine, Go, Inventory, Look, LookToward, Say, Take, Unknown,
}
import server/llm
import server/world/builder
import server/world/map
import server/world/room
import server/world/seed
import server/world/store
import server/world/types.{Down, East, Exit, North, Up, West}

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn directions_test() {
  assert command.parse("n") == Go(North)
  assert command.parse("  North ") == Go(North)
  assert command.parse("go down") == Go(Down)
  assert command.parse("climb d") == Go(Down)
  assert command.parse("go sideways") == Unknown("go sideways")
}

pub fn verbs_test() {
  assert command.parse("l") == Look
  assert command.parse("look at the lantern") == Examine("the lantern")
  assert command.parse("x the ladder") == Examine("ladder")
  assert command.parse("pick up the brass key") == Take("brass key")
  assert command.parse("get oil") == Take("oil")
  assert command.parse("drop the pole") == Drop("pole")
  assert command.parse("i") == Inventory
}

pub fn say_keeps_original_case_test() {
  assert command.parse("say Hello, Ada!") == Say("Hello, Ada!")
  assert command.parse("'Who goes there?") == Say("Who goes there?")
  assert command.parse("say   ") == Unknown("say")
}

pub fn free_text_is_unknown_test() {
  assert command.parse("sneak past the guard")
    == Unknown("sneak past the guard")
}

pub fn item_name_test() {
  assert builder.item_name("A rusted bell clapper, half-buried in the dust")
    == "rusted bell clapper"
  assert builder.item_name("small, rusty key") == "small rusty key"
  assert builder.item_name("The Brass Key.") == "brass key"
  assert builder.item_name("tin of lamp oil") == "tin of lamp oil"
  assert builder.item_name("an old map lying on the floor") == "old map"
}

pub fn mentions_test() {
  let text = "Cracked shells crunch underfoot beside a burnt offering."
  assert builder.mentions(text, "cracked shell")
  assert builder.mentions(text, "burnt offering")
  assert builder.mentions("A fish, seaweed and all.", "seaweed-wrapped fish")
  assert !builder.mentions("Fog everywhere.", "rusty fishhook")
  assert builder.mentions(
      "A tin of lamp oil sits at the lantern's foot.",
      "lamplighter's hooked pole",
    )
    == False
}

pub fn look_toward_parse_test() {
  assert command.parse("look north") == LookToward(North)
  assert command.parse("look to the east") == LookToward(East)
  assert command.parse("x up") == LookToward(Up)
  assert command.parse("look at the stairs") == Examine("the stairs")
}

pub fn look_toward_wording_test() {
  let exits = [
    Exit(
      North,
      "worn stone stairs climb toward a broken bell tower",
      "x",
      None,
      None,
      None,
    ),
    Exit(Down, "An iron grate breathes warm air.", "x", None, None, None),
    Exit(West, "back toward The Lantern Crossroads", "x", Some(1), None, None),
  ]
  assert room.look_toward(exits, North)
    == "To the north, worn stone stairs climb toward a broken bell tower."
  assert room.look_toward(exits, Down)
    == "Below, an iron grate breathes warm air."
  assert room.look_toward(exits, West)
    == "To the west, the way leads back to The Lantern Crossroads."
  assert room.look_toward(exits, East) == "There's no way east from here."
}

pub fn unique_name_test() {
  assert builder.unique_name("Brick Warren", ["the lantern crossroads"])
    == "Brick Warren"
  assert builder.unique_name("Saltwater's Dark Bend", ["saltwater's dark bend"])
    == "Old Saltwater's Dark Bend"
  assert builder.unique_name("The Quay", [
      "the quay",
      "old quay",
    ])
    == "Little Quay"
  assert builder.unique_name("A Fog-Choked Passage", ["a fog-choked passage"])
    == "Old Fog-Choked Passage"
}

fn room_with(id: Int, exits: List(#(types.Direction, Int))) -> types.Room {
  types.Room(
    id:,
    region: "r",
    name: "Room " <> int.to_string(id),
    description: "",
    features: [],
    items: [],
    exits: list.map(exits, fn(e) { Exit(e.0, "", "r", Some(e.1), None, None) }),
    art_url: None,
    picture: "",
    x: 0,
    y: 0,
    z: 0,
    dark: False,
  )
}

fn cell(placed: List(map.Placed), id: Int) -> #(Int, Int, Int) {
  let assert Ok(p) = list.find(placed, fn(p) { p.room.id == id })
  #(p.x, p.y, p.z)
}

pub fn map_follows_directions_test() {
  let placed =
    map.layout(
      [
        room_with(1, [#(North, 2), #(Down, 3)]),
        room_with(2, [#(types.South, 1), #(East, 4)]),
        room_with(3, [#(Up, 1)]),
        room_with(4, [#(West, 2)]),
      ],
      [1],
    )
  assert cell(placed, 1) == #(0, 0, 0)
  assert cell(placed, 2) == #(0, -1, 0)
  assert cell(placed, 3) == #(0, 0, -1)
  assert cell(placed, 4) == #(1, -1, 0)
}

pub fn map_moves_colliding_rooms_aside_test() {
  // 1 → east 2 → north 3 → west 4 → south… would land on 1 again, but the
  // generated world says 4's south is a different room, 5.
  let placed =
    map.layout(
      [
        room_with(1, [#(East, 2)]),
        room_with(2, [#(West, 1), #(North, 3)]),
        room_with(3, [#(types.South, 2), #(West, 4)]),
        room_with(4, [#(East, 3), #(types.South, 5)]),
        room_with(5, [#(North, 4)]),
      ],
      [1],
    )
  let cells = list.map(placed, fn(p) { #(p.x, p.y, p.z) })
  assert list.length(list.unique(cells)) == 5
  assert cell(placed, 4) == #(0, -1, 0)
  assert cell(placed, 5) != #(0, 0, 0)
}

pub fn map_places_unreachable_rooms_apart_test() {
  let placed =
    map.layout(
      [room_with(1, [#(East, 2)]), room_with(2, []), room_with(9, [])],
      [
        1,
      ],
    )
  let #(x, _, _) = cell(placed, 9)
  assert x > 1
}

pub fn exit_into_built_cell_joins_that_room_test() {
  let db = store.open(":memory:")
  let start = seed.run(db)
  // A room already standing one step east of the crossroads, with no way
  // back west yet.
  let assert Ok(east) =
    store.insert_room(
      db,
      "drowned_quarter",
      "Quay",
      "A wet quay.",
      [],
      [],
      [],
      #(1, 0, 0),
    )
  let assert Ok(from) = store.load_room(db, start)
  let assert Ok(exit) = types.find_exit(from, East)
  // The model is never asked: an unreachable endpoint proves it.
  let nowhere = llm.Client(llm.Ollama("http://127.0.0.1:9"), "none")
  let built = builder.build(db, nowhere, from, exit)
  assert built.room_id == east
  assert !built.new
  let assert Ok(from) = store.load_room(db, start)
  let assert Ok(Exit(target: Some(t), ..)) = types.find_exit(from, East)
  assert t == east
  // …and the quay was given a way back.
  let assert Ok(quay) = store.load_room(db, east)
  let assert Ok(Exit(target: Some(back), ..)) = types.find_exit(quay, West)
  assert back == start
}

pub fn one_room_per_cell_test() {
  let db = store.open(":memory:")
  let _ = seed.run(db)
  // The seed holds (0, 0, 0); a second room there is refused.
  assert store.insert_room(db, "warrens", "Clash", "Nope.", [], [], [], #(
      0,
      0,
      0,
    ))
    == Error(Nil)
  assert store.room_at(db, #(0, 0, 0)) == Some(1)
}

pub fn image_prompt_test() {
  // Room pictures are establishing shots: style, then the setting only,
  // whichever form the picture line was stored in.
  let setting_only =
    types.Room(..room_with(1, []), picture: "A quay at dusk, barges moored.")
  assert art.image_prompt(setting_only)
    == art.style <> ". A quay at dusk, barges moored."
  let close_up_form =
    types.Room(
      ..room_with(2, []),
      picture: "Close-up of a brass key, large in the foreground. Behind: a quay at dusk.",
    )
  assert art.image_prompt(close_up_form) == art.style <> ". a quay at dusk."
  let foreground_form =
    types.Room(
      ..room_with(3, []),
      picture: "A quay at dusk. In the foreground: brass key, rope.",
    )
  assert art.image_prompt(foreground_form) == art.style <> ". A quay at dusk."
  // No line at all: the place and its first few details.
  let none =
    types.Room(
      ..room_with(4, []),
      name: "The Quay",
      features: ["wet stones", "moored barges", "gulls", "rope coils"],
      items: ["brass key"],
    )
  assert art.image_prompt(none)
    == art.style <> ". The Quay: wet stones, moored barges, gulls."
}

pub fn closeup_prompt_test() {
  // The thing alone and large; the room only as a blurred hint.
  let room = types.Room(..room_with(1, []), name: "The Quay")
  let key =
    store.Examinable("item-7", "brass key", "a small tarnished brass key.")
  assert art.closeup_prompt(room, key)
    == art.style
    <> ". Close-up of a small tarnished brass key, centered, filling the frame, finely detailed. Softly blurred background: The Quay."
}

pub fn first_sentence_test() {
  assert builder.first_sentence(
      "A dimly lit street with a worn stone bellway. A vendor sells salmon.",
      30,
    )
    == "A dimly lit street with a worn stone bellway"
  assert builder.first_sentence("one two three four five", 3) == "one two three"
  assert builder.first_sentence("", 30) == ""
}

pub fn lock_and_key_test() {
  let db = store.open(":memory:")
  let start = seed.run(db)
  store.lock_exit(
    db,
    start,
    East,
    "lock-test",
    "an iron gate with a raven keyhole",
  )
  // No key: barred, with what bars the way.
  assert store.pass(db, "Ada", start, East)
    == store.Barred("an iron gate with a raven keyhole")
  // A key lying in the next room, made for this lock; carry it.
  let assert Ok(quay) =
    store.insert_room(
      db,
      "drowned_quarter",
      "Quay",
      "A quay.",
      [],
      ["raven key"],
      [],
      #(1, 0, 0),
    )
  store.set_item_role(db, quay, "raven key", "key", Some("lock-test"))
  let assert Ok(_) = store.take_item(db, quay, "Ada", "raven key")
  // Someone else without it is still barred.
  assert store.pass(db, "Bram", start, East)
    == store.Barred("an iron gate with a raven keyhole")
  // With it: unlocked, key left in the lock, and open for good — for anyone.
  assert store.pass(db, "Ada", start, East)
    == store.Unlocked("raven key", "an iron gate with a raven keyhole")
  assert store.inventory(db, "Ada") == []
  assert store.pass(db, "Bram", start, East) == store.Open
  // Other exits were never locked.
  assert store.pass(db, "Bram", start, North) == store.Open
}

pub fn promised_items_test() {
  let db = store.open(":memory:")
  let _ = seed.run(db)
  let key =
    store.Pending("raven key", "a black iron key", "key", Some("lock-1"))
  store.add_pending(db, #(2, 0, 0), key)
  assert store.pending_at(db, #(2, 0, 0)) == [key]
  assert store.pending_at(db, #(3, 0, 0)) == []
  store.clear_pending(db, #(2, 0, 0))
  assert store.pending_at(db, #(2, 0, 0)) == []
}

pub fn repeats_test() {
  let before =
    "A lamplighter's ladder leans against the post, a hooked pole propped beside it."
  assert builder.repeats(
    "Water laps the dock. A lamplighter's ladder leans against the post, a hooked pole propped beside it.",
    before,
  )
  assert !builder.repeats(
    "Water laps at a sagging dock, and a ladder lies broken in the mud.",
    before,
  )
}

pub fn underground_test() {
  assert builder.above_ground_words("A narrow alley under a grey sky.", -1)
    == ["alley", "sky"]
  assert builder.above_ground_words("A dripping brick sewer tunnel.", -1) == []
  // At or above street level, streets are fine.
  assert builder.above_ground_words("A narrow alley under a grey sky.", 0) == []
}

pub fn key_name_test() {
  assert builder.key_name("Raven's Claw") == "raven's claw key"
  assert builder.key_name("brass key") == "brass key"
  assert builder.key_name("") == "iron key"
}

pub fn barred_test() {
  assert types.barred("an iron gate with a raven keyhole")
    == "An iron gate with a raven keyhole bars the way. It's locked."
  assert types.barred("A sturdy gate bars the way.")
    == "A sturdy gate bars the way. It's locked."
}

pub fn only_takeable_roles_test() {
  let db = store.open(":memory:")
  let _ = seed.run(db)
  // Items without a role the game uses are scenery: not shown, not taken.
  let assert Ok(room) =
    store.insert_room(
      db,
      "warrens",
      "Den",
      "A den.",
      [],
      ["old spoon", "brass key"],
      [],
      #(0, 0, -1),
    )
  store.set_item_role(db, room, "old spoon", "valuable", None)
  store.set_item_role(db, room, "brass key", "key", Some("lock-x"))
  assert store.room_items(db, room) == ["brass key"]
  assert store.take_item(db, room, "Ada", "old spoon") == Error(Nil)
  assert store.take_item(db, room, "Ada", "brass key") == Ok("brass key")
  // The seed room's pole is a tool and its oil tin fuel: both takeable.
  assert store.room_items(db, 1)
    == ["lamplighter's hooked pole", "tin of lamp oil"]
}

pub fn lantern_and_oil_test() {
  let db = store.open(":memory:")
  let _ = seed.run(db)
  let assert Ok(cellar) =
    store.insert_room(
      db,
      "warrens",
      "Cellar",
      "A cellar.",
      [],
      ["bullseye lantern", "tin of lamp oil"],
      [],
      #(0, 0, -1),
    )
  store.set_item_role(db, cellar, "bullseye lantern", "light", None)
  store.set_item_charge(db, cellar, "bullseye lantern", 2)
  store.set_item_role(db, cellar, "tin of lamp oil", "fuel", None)
  // Nobody has it yet: one free light.
  assert store.free_lights(db) == 1
  assert !store.has_light(db, "Ada")
  let assert Ok(_) = store.take_item(db, cellar, "Ada", "bullseye lantern")
  assert store.free_lights(db) == 0
  assert store.has_light(db, "Ada")
  // Two steps in the dark and it's out.
  assert store.burn(db, "Ada") == Some(#("bullseye lantern", 1))
  assert store.burn(db, "Ada") == Some(#("bullseye lantern", 0))
  assert !store.has_light(db, "Ada")
  assert store.burn(db, "Ada") == None
  // No oil carried yet.
  assert store.refill(db, "Ada") == Error("You have no oil to fill it with.")
  let assert Ok(_) = store.take_item(db, cellar, "Ada", "tin of lamp oil")
  assert store.refill(db, "Ada")
    == Ok(#("bullseye lantern", "tin of lamp oil", types.lantern_oil))
  assert store.has_light(db, "Ada")
  // The tin is used up.
  assert store.inventory(db, "Ada") == ["bullseye lantern"]
}

pub fn light_is_promised_at_street_level_test() {
  let db = store.open(":memory:")
  let _ = seed.run(db)
  // The crossroads has unbuilt ways north, east and west at street level
  // (down leads below it): a light goes beyond one of those.
  let assert Some(#(_, _, z)) = store.street_cell_for_light(db)
  assert z == 0
}

pub fn obstacle_and_tool_test() {
  let db = store.open(":memory:")
  let start = seed.run(db)
  store.set_obstacle(
    db,
    start,
    West,
    types.Obstacle("pole", "a ladder pulled up out of reach"),
  )
  // Without a pole: blocked, and told what's needed.
  let assert store.Obstructed(o) = store.pass(db, "Ada", start, West)
  assert types.obstructed(o)
    == "A ladder pulled up out of reach blocks the way. You'd need something long to reach it."
  // The crossroads' own hooked pole is the tool; one is free until taken.
  assert store.free_tools(db, "pole") == 1
  let assert Ok(_) = store.take_item(db, start, "Ada", "hooked pole")
  assert store.free_tools(db, "pole") == 0
  let assert store.Cleared(tool: "lamplighter's hooked pole", ..) =
    store.pass(db, "Ada", start, West)
  // Cleared for everyone; the tool is kept.
  assert store.pass(db, "Bram", start, West) == store.Open
  assert store.inventory(db, "Ada") == ["lamplighter's hooked pole"]
}

pub fn difficulty_test() {
  // Near the crossroads is gentle; underground counts double.
  assert builder.tier(#(0, 0, 0)) == 0
  assert builder.tier(#(1, -1, 0)) == 0
  assert builder.tier(#(0, 0, -1)) == 0
  assert builder.tier(#(1, 0, -1)) == 1
  assert builder.tier(#(3, 2, 0)) == 1
  assert builder.tier(#(2, 2, -1)) == 2
  // Gentle places have nothing in the way.
  assert builder.odds(0)
    == builder.Odds(dark: 0, obstacle: 0, lock: 0, gift: 30)
}

pub fn obstacle_words_test() {
  let fits = fn(kind, desc) {
    builder.obstacle_words(kind) |> list.any(string.contains(desc, _))
  }
  assert fits("crowbar", "a rusted iron grate, its hinges seized")
  assert !fits("crowbar", "a decrepit, oil-stained wooden wheel")
  assert fits("rope", "a sheer drop where the stairs have fallen away")
  assert fits("pole", "a ladder pulled up well out of reach")
}
