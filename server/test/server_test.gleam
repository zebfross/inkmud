import gleam/int
import gleam/list
import gleam/option.{None, Some}
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
    Exit(North, "worn stone stairs climb toward a broken bell tower", "x", None),
    Exit(Down, "An iron grate breathes warm air.", "x", None),
    Exit(West, "back toward The Lantern Crossroads", "x", Some(1)),
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
    == "Lower Saltwater's Dark Bend"
  assert builder.unique_name("The Quay", [
      "the quay",
      "lower quay",
    ])
    == "Upper Quay"
  assert builder.unique_name("A Fog-Choked Passage", ["a fog-choked passage"])
    == "Lower Fog-Choked Passage"
}

fn room_with(id: Int, exits: List(#(types.Direction, Int))) -> types.Room {
  types.Room(
    id:,
    region: "r",
    name: "Room " <> int.to_string(id),
    description: "",
    features: [],
    items: [],
    exits: list.map(exits, fn(e) { Exit(e.0, "", "r", Some(e.1)) }),
    art_url: None,
    picture: "",
    x: 0,
    y: 0,
    z: 0,
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
  // A line in the current form is used as written, after the style.
  let room =
    types.Room(
      ..room_with(1, []),
      picture: "Close-up of a brass key, large in the foreground. Behind: a quay.",
    )
  assert art.image_prompt(room)
    == art.style
    <> ". Close-up of a brass key, large in the foreground. Behind: a quay."
  // The earlier "setting. In the foreground: items." form becomes a close-up.
  let older =
    types.Room(
      ..room_with(3, []),
      picture: "A quay at dusk. In the foreground: brass key, rope.",
    )
  assert art.image_prompt(older)
    == art.style
    <> ". Close-up of brass key and rope, large in the foreground. Behind: A quay at dusk."
  // No line at all: composed from the stored facts.
  let oldest =
    types.Room(
      ..room_with(2, []),
      name: "The Quay",
      features: ["wet stones", "moored barges", "gulls", "rope coils"],
      items: ["brass key"],
    )
  assert art.image_prompt(oldest)
    == art.style
    <> ". Close-up of brass key, large in the foreground. Behind: The Quay: wet stones, moored barges, gulls."
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
