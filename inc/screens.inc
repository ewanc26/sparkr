; inc/screens.inc — Public interface for the Sparkr screens module.
;
; Provides:
;   Screens::loop_title     — title screen (call before World::init at startup)
;   Screens::show_paused    — queue "PAUSED" nametable overlay
;   Screens::hide_paused    — queue blank tiles over "PAUSED"
;   Screens::loop_gameover  — game-over screen (calls World::init #0 on exit)

.ifndef Screens_included
Screens_included = 1

.scope Screens

    ; -----------------------------------------------------------------------
    ; Font tile indices (patched into background.chr by chr/gen_font.py)
    ; -----------------------------------------------------------------------
    TILE_A      = $47
    TILE_D      = $48
    TILE_E      = $49
    TILE_G      = $4A
    TILE_K      = $4B
    TILE_M      = $4C
    TILE_O      = $4D
    TILE_P      = $4E
    TILE_R      = $4F
    TILE_S      = $5A
    TILE_T      = $5B
    TILE_U      = $5C
    TILE_V      = $5D
    TILE_SPACE  = $00

    ; -----------------------------------------------------------------------
    ; Subroutines
    ; -----------------------------------------------------------------------
    ; loop_title: call at startup before World::init; rendering must be off.
    ;   Draws title screen, waits for START, returns with rendering on.
    .import loop_title

    ; show_paused: queue "PAUSED" into the nmt update buffer.
    ;   Call before PPU::update at the start of loop_paused.
    .import show_paused

    ; hide_paused: queue 6 blank tiles over "PAUSED" into the nmt update buffer.
    ;   Call after the pause loop, before the final PPU::update.
    .import hide_paused

    ; loop_gameover: draw game-over screen, wait for START, call World::init #0.
    ;   Call when player_hp == 0.  Returns ready for loop_gameplay.
    .import loop_gameover

.endscope ; Screens

.endif ; Screens_included
