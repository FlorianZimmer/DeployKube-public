// priority: 50
/**
 * DeployKube server divergence: MV-age Maceration Tower multiblock.
 *
 * Goal: provide a "fast-ish" maceration option before IV without pulling in a custom Java mod.
 * This is intentionally simple: it reuses the standard macerator recipe type.
 */

GTCEuStartupEvents.registry("gtceu:machine", event => {
  // This script is only copied onto the persistent PVC when the feature is enabled
  // (see the deploykube-mv-maceration-tower initContainer in deployment.yaml).

  event
    .create("deploykube_mv_maceration_tower", "multiblock")
    .rotationState(RotationState.NON_Y_AXIS)
    .recipeTypes("macerator")
    .recipeModifiers([GTRecipeModifiers.OC_NON_PERFECT_SUBTICK, GTRecipeModifiers.BATCH_MODE])
    .appearanceBlock(GTBlocks.CASING_STEEL_SOLID)
    .pattern(definition =>
      FactoryBlockPattern.start()
        .aisle("CCC", "C@C", "C C", "CCC")
        .aisle("CCC", "C C", "C C", "CCC")
        .aisle("CCC", "C C", "C C", "CCC")
        .where("@", Predicates.controller(Predicates.blocks(definition.get())))
        .where(
          "C",
          Predicates.blocks(GTBlocks.CASING_STEEL_SOLID.get())
            .setMinGlobalLimited(24)
            .or(Predicates.autoAbilities(definition.getRecipeTypes()))
            .or(Predicates.abilities(PartAbility.MAINTENANCE).setExactLimit(1)),
        )
        .where(" ", Predicates.air())
        .build(),
    )
    .workableCasingModel(
      "gtceu:block/casings/solid/machine_casing_solid_steel",
      "gtceu:block/machines/macerator",
    )
})
