// priority: -11
/**
 * DeployKube: Ensure items that Monifactory nukes (tags removed + recipes removed) are also unobtainable by chance.
 *
 * This filters loot outputs (blocks/chests/entities/gameplay). Non-loot sources need separate handling.
 */
LootJS.modifiers((event) => {
  const modifier = event.addLootTableModifier(/.*/)

  // Explicit nukelist (strings + regexes).
  if (global.itemNukeList) {
    global.itemNukeList.forEach((item) => {
      modifier.removeLoot(item)
    })
  }

  // Broad unification patterns.
  if (global.unificationPattern) modifier.removeLoot(global.unificationPattern)
  if (global.nuclearcraftFuelPattern) modifier.removeLoot(global.nuclearcraftFuelPattern)
  if (global.nuclearcraftIsotopePattern) modifier.removeLoot(global.nuclearcraftIsotopePattern)
})
