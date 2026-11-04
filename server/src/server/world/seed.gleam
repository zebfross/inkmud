//// The part of the world planned in advance: the setting guide every
//// generated room is written against, the regions, and the first room.
//// Everything past the first room's exits is built as players explore.

import gleam/option.{None}
import server/world/store.{type Store, NewExit}
import server/world/types.{Down, East, North, Region, West}

/// Given to every model call that invents world content. The era section is
/// what keeps a 3B model (and the image model after it) from drifting into
/// medieval castles one room and modern alleys the next: name the period,
/// say what exists, and say what doesn't.
pub const setting = "Vellmoor is an old harbour city of gaslight and fog, built on the bones of an older city that sank beneath it. The fog never fully lifts. Lamplighters tend the gas lamps on long ladders and are half-trusted, half-feared. Bells from the ruined cathedral still ring on their own some nights. Beneath the streets run brick sewers and warrens where goblins in patched waistcoats trade in stolen pocket watches and trinkets. To the east the streets slope down into the Drowned Quarter, where the sea has come in and smugglers pole flat boats between rooftops.

Era: a gaslamp age, like the 1860s to 1880s, but Vellmoor is its own city with no real-world places, people or history. What exists: gas street lamps, oil lanterns, candles, coal smoke, chimneys, soot, brick and cast iron, cobblestones, wrought-iron railings, horse-drawn carriages and handcarts, river barges, pawnshops, gin houses, apothecaries, printing presses, pocket watches, greatcoats, waistcoats, bonnets, top hats, shawls. What does not exist: electricity, electric light, cars, bicycles, telephones, plastic, neon, guns of any modern kind, castles, knights, swords-and-sorcery magic.

Tone: melancholy, eerie, quietly wondrous; low magic that is uncanny rather than flashy. Write in second person present tense, concise and sensory."

pub const start_room_name = "The Lantern Crossroads"

/// Writes the regions and the first room into an empty database. Returns
/// the first room's id.
pub fn run(store: Store) -> Int {
  store.insert_region(
    store,
    Region(
      id: "lantern_ward",
      name: "Lantern Ward",
      theme: "narrow gaslit lanes, shuttered shopfronts with painted signs, pawnshops and apothecaries, lamplighters on ladders, cats on soot-black rooftops, the smell of gas, coal smoke and wet stone",
    ),
  )
  store.insert_region(
    store,
    Region(
      id: "cathedral_hill",
      name: "Cathedral Hill",
      theme: "steep stone stairs, a ruined gothic cathedral and its chapels, collapsed slate roofs, iron gates, overgrown graveyards with leaning headstones, ravens, bells that ring by themselves, moss on broken saints",
    ),
  )
  store.insert_region(
    store,
    Region(
      id: "drowned_quarter",
      name: "The Drowned Quarter",
      theme: "flooded brick streets, half-sunken market stalls and warehouses, lanterns on poles above black water, rope bridges between rooftops, salt and rot, smugglers on flat boats, eels in the dark water",
    ),
  )
  store.insert_region(
    store,
    Region(
      id: "warrens",
      name: "The Warrens",
      theme: "brick sewers and low tunnels beneath the city, candle stubs and stolen lanterns, crude goblin totems hung with pocket watches and spoons, piles of stolen trinkets, warm stale air, glowing eyes",
    ),
  )
  let assert Ok(start) =
    store.insert_room(
      store,
      "lantern_ward",
      start_room_name,
      "Four streets meet beneath a cast-iron gas lamp taller than any house, its glass stained amber with age and its flame hissing softly. Fog pools around your ankles. A lamplighter's ladder leans against the post, a hooked pole propped beside it and a tin of lamp oil at its foot, but their owner is nowhere to be seen. Somewhere far above, a bell rings once and falls silent.",
      [
        "towering cast-iron gas lamp with amber glass",
        "fog pooling on cobblestones",
        "an abandoned lamplighter's ladder",
        "four cobbled streets meeting in a small square, shuttered shopfronts",
      ],
      ["lamplighter's hooked pole", "tin of lamp oil"],
      [
        NewExit(
          North,
          "worn stone stairs climb toward the dark shape of a broken bell tower",
          "cathedral_hill",
          None,
        ),
        NewExit(
          East,
          "the street slopes down into black water; you smell salt",
          "drowned_quarter",
          None,
        ),
        NewExit(
          West,
          "a narrow lane of shuttered shops, every window lit",
          "lantern_ward",
          None,
        ),
        NewExit(
          Down,
          "an iron grate in the cobbles breathes warm, stale air",
          "warrens",
          None,
        ),
      ],
      // The centre of the city's grid.
      #(0, 0, 0),
    )
  store.set_picture(
    store,
    start,
    "A foggy square where four cobbled streets meet beneath a towering cast-iron gas lamp with amber glass, a ladder leaning on it, shuttered shopfronts all around.",
  )
  store.set_item_look(
    store,
    start,
    "lamplighter's hooked pole",
    "a long wooden pole with an iron hook at its tip",
  )
  store.set_item_look(
    store,
    start,
    "tin of lamp oil",
    "a small dented tin can of oil with a cork stopper",
  )
  store.save_build_debug(
    store,
    start,
    "(hand-written in server/src/server/world/seed.gleam; no model was asked)",
    [],
  )
  start
}
