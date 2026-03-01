; inc/world.inc — Public interface for the Sparkr world/level management module.

.ifndef World_included
World_included = 1

.scope World

    NUM_WORLDS = 3

    ; -----------------------------------------------------------------------
    ; Zero-page
    ; -----------------------------------------------------------------------
    .importzp cur_world     ; current world index (0-2)

    ; -----------------------------------------------------------------------
    ; Subroutines
    ; -----------------------------------------------------------------------
    ; init: A = world number — turns off rendering, rebuilds background,
    ;        loads palette, spawns enemies, resets player.
    .import init

    ; next: advance to the next world (wraps 2 → 0) and call init.
    .import next

    ; render_hud: draw OAM heart sprites based on Player::player_hp.
    ;             Call once per frame before PPU::update.
    .import render_hud

.endscope ; World

.endif ; World_included
