/**
 * DeployKube server divergence: MV-age Maceration Tower multiblock controller recipe.
 */

ServerEvents.recipes(event => {
  event
    .shaped("gtceu:deploykube_mv_maceration_tower", ["PMP", "HSH", "CWC"], {
      P: "gtceu:mv_electric_piston",
      M: "gtceu:mv_electric_motor",
      H: "gtceu:mv_machine_hull",
      S: "gtceu:mv_macerator",
      C: "#gtceu:circuits/mv",
      W: "gtceu:copper_single_cable",
    })
    .id("deploykube:shaped/mv_maceration_tower")
})
