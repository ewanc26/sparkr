; asm/screens.s
;
; Sparkr — Title screen, pause overlay, and game-over screen
;
; Three exported entry points:
;
;   Screens::loop_title
;       Called at startup (rendering off).  Draws "SPARKR" + blinking
;       "PRESS START", then waits for START.  Returns with rendering ON.
;       Caller (main) immediately calls World::init which takes the palette
;       over for gameplay.
;
;   Screens::show_paused / Screens::hide_paused
;       Queue nametable writes via the PPU update buffer.  Call
;       show_paused before the first PPU::update inside loop_paused;
;       call hide_paused after the last one.  Both are single-frame
;       operations — no render_off required.
;
;   Screens::loop_gameover
;       Turns rendering off, clears the background, draws "GAME OVER"
;       and three empty heart tiles, then waits for START.  On exit
;       calls World::init #0 (resets HP, enemies, background) before
;       returning.
;
; FONT TILES
;   Letters A D E G K M O P R S T U V live at tile indices $47–$4F
;   and $5A–$5D in background.chr, patched in by chr/gen_font.py.
;   They use NES colour 2 only (plane0 = 0, plane1 = glyph mask).
;   The screens each load a palette that puts the desired text colour
;   into bg-palette-0 slot 2.

.fileopt comment, "Sparkr screen management"
.fileopt author,  "Sparkr project"

.include "locals.inc"
.include "ppu.inc"
.include "joy.inc"
.include "world.inc"
.include "math_macros.inc"

.scope Screens

; ===========================================================================
; Font tile constants (colour-2 glyphs patched into background.chr)
; ===========================================================================
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

; Heart glyph (world.s uses this tile index for an empty heart in the HUD)
TILE_HEART_EMPTY = $28

; ===========================================================================
; Layout constants (nametable tile coordinates, col 0-31, row 0-29)
; ===========================================================================

; "SPARKR"  — 6 chars, (32-6)/2 = 13
TITLE_TEXT_ROW  = 7
TITLE_TEXT_COL  = 13
; "PRESS START" — 11 chars, (32-11)/2 = 10
PROMPT_ROW  = 11
PROMPT_COL  = 10
; "PAUSED" — 6 chars, (32-6)/2 = 13  (row 1 = sky strip, naturally blank)
PAUSE_ROW   = 1
PAUSE_COL   = 13
; "GAME OVER" — 9 chars, (32-9)/2 = 11
GAMEOVER_ROW        = 12
GAMEOVER_COL        = 11
; Three empty hearts below: (32-3)/2 = 14
GAMEOVER_HEARTS_ROW = 15
GAMEOVER_HEARTS_COL = 14

; ===========================================================================
; Read-only data
; ===========================================================================
.segment "RODATA"

; ---------------------------------------------------------------------------
; Title screen palette
;   bg-pal-0: black bg / dark-green / WHITE / bright-green
;   Text tiles use colour 2 → white ($30).
; ---------------------------------------------------------------------------
title_palette:
    .byte $0F, $09, $30, $19    ; bg0
    .byte $0F, $09, $30, $19    ; bg1
    .byte $0F, $09, $30, $19    ; bg2
    .byte $0F, $09, $30, $19    ; bg3
    .byte $0F, $0F, $0F, $0F    ; sp0 (sprites hidden on title)
    .byte $0F, $0F, $0F, $0F    ; sp1
    .byte $0F, $0F, $0F, $0F    ; sp2
    .byte $0F, $0F, $0F, $0F    ; sp3

; ---------------------------------------------------------------------------
; Game-over palette
;   bg-pal-0: black bg / dark-red / RED-ORANGE / bright-orange
;   Text tiles use colour 2 → red-orange ($36).
; ---------------------------------------------------------------------------
gameover_palette:
    .byte $0F, $06, $36, $16    ; bg0
    .byte $0F, $06, $36, $16    ; bg1
    .byte $0F, $06, $36, $16    ; bg2
    .byte $0F, $06, $36, $16    ; bg3
    .byte $0F, $0F, $0F, $0F    ; sprites hidden
    .byte $0F, $0F, $0F, $0F
    .byte $0F, $0F, $0F, $0F
    .byte $0F, $0F, $0F, $0F

; ===========================================================================
; CODE
; ===========================================================================
.segment "CODE"

; ---------------------------------------------------------------------------
; Screens::loop_title
;   Pre-condition: rendering is off (guaranteed by PPU::reset on first boot).
;   1. Loads the title palette into palette_buffer.
;   2. Clears the nametable.
;   3. Draws "SPARKR" and "PRESS START" directly via REG_DATA.
;   4. Enables rendering (stores ctrl/mask ready for first PPU::update).
;   5. Blinks "PRESS START" using the nmt update buffer until START.
;   Post-condition: returns with rendering ON, title palette loaded.
;   Caller (main) then calls World::init to take over.
; ---------------------------------------------------------------------------
.export loop_title
.proc loop_title
    ; Confirm rendering is off (waits one NMI; no-op if already off)
    jsr PPU::render_off

    ; Load title palette into buffer (pushed to PPU by first PPU::update)
    ldx #0
    :
        lda title_palette, X
        sta PPU::palette_buffer, X
        inx
        cpx #32
        bcc :-

    ; Clear the nametable
    jsr PPU::clear_background

    ; -------------------------------------------------------------------
    ; Draw "SPARKR" at tile row TITLE_TEXT_ROW, starting at col TITLE_TEXT_COL
    ; -------------------------------------------------------------------
    ldx #TITLE_TEXT_COL
    ldy #TITLE_TEXT_ROW
    jsr PPU::address_tile
    lda #TILE_S  : sta PPU::REG_DATA
    lda #TILE_P  : sta PPU::REG_DATA
    lda #TILE_A  : sta PPU::REG_DATA
    lda #TILE_R  : sta PPU::REG_DATA
    lda #TILE_K  : sta PPU::REG_DATA
    lda #TILE_R  : sta PPU::REG_DATA

    ; -------------------------------------------------------------------
    ; Draw static "PRESS START" (will blink once loop starts)
    ; -------------------------------------------------------------------
    ldx #PROMPT_COL
    ldy #PROMPT_ROW
    jsr PPU::address_tile
    lda #TILE_P     : sta PPU::REG_DATA
    lda #TILE_R     : sta PPU::REG_DATA
    lda #TILE_E     : sta PPU::REG_DATA
    lda #TILE_S     : sta PPU::REG_DATA
    lda #TILE_S     : sta PPU::REG_DATA
    lda #TILE_SPACE : sta PPU::REG_DATA
    lda #TILE_S     : sta PPU::REG_DATA
    lda #TILE_T     : sta PPU::REG_DATA
    lda #TILE_A     : sta PPU::REG_DATA
    lda #TILE_R     : sta PPU::REG_DATA
    lda #TILE_T     : sta PPU::REG_DATA

    ; Enable rendering for the wait loop (pushed to PPU on first update)
    lda #%10001000
    sta PPU::ctrl
    lda #%00011110
    sta PPU::mask

    ; -------------------------------------------------------------------
    ; Wait for START, blinking "PRESS START" each ~32 frames.
    ; local_0 = prompt_visible flag (1 = currently showing)
    ; -------------------------------------------------------------------
    prompt_visible = local_0
    lda #1
    sta prompt_visible          ; tiles were just written directly above

@blink_loop:
    jsr PPU::update             ; push palette + any pending nmt writes

    ; nmi_count bit 5 toggles every 32 frames → ~0.5 s on, ~0.5 s off
    lda PPU::nmi_count
    and #$20
    bne @maybe_hide

    ; -- phase: SHOW --
    lda prompt_visible
    bne @poll_start             ; already visible
    jsr prompt_write            ; queue tiles to nmt buffer
    lda #1
    sta prompt_visible
    jmp @poll_start

@maybe_hide:
    ; -- phase: HIDE --
    lda prompt_visible
    beq @poll_start             ; already hidden
    jsr prompt_clear            ; queue spaces to nmt buffer
    lda #0
    sta prompt_visible

@poll_start:
    jsr Joy::store_new_buttons
    and #Joy::BUTTON_START
    beq @blink_loop

    ; Ensure the prompt is visible on transition (clean final frame)
    lda prompt_visible
    bne @done
    jsr prompt_write
    jsr PPU::update
@done:
    rts
.endproc

; ---------------------------------------------------------------------------
; prompt_write  (internal)
;   Queue "PRESS START" tiles into the nmt update buffer.
;   Uses PPU::update_tile_at_xy for the first tile, then
;   PPU::update_next_byte for the remaining ten sequential tiles.
;   update_next_byte preserves A; update_tile_at_xy clobbers A (returns 0).
; ---------------------------------------------------------------------------
.proc prompt_write
    lda #TILE_P
    ldx #PROMPT_COL
    ldy #PROMPT_ROW
    jsr PPU::update_tile_at_xy      ; A = 0 (success) on return
    lda #TILE_R  : jsr PPU::update_next_byte
    lda #TILE_E  : jsr PPU::update_next_byte
    lda #TILE_S  : jsr PPU::update_next_byte
    lda #TILE_S  : jsr PPU::update_next_byte
    lda #TILE_SPACE : jsr PPU::update_next_byte
    lda #TILE_S  : jsr PPU::update_next_byte
    lda #TILE_T  : jsr PPU::update_next_byte
    lda #TILE_A  : jsr PPU::update_next_byte
    lda #TILE_R  : jsr PPU::update_next_byte
    lda #TILE_T  : jsr PPU::update_next_byte
    rts
.endproc

; ---------------------------------------------------------------------------
; prompt_clear  (internal)
;   Queue 11 blank tiles over "PRESS START" in the nmt update buffer.
;   TILE_SPACE = $00; update_tile_at_xy also returns 0 in A on success,
;   so A is already $00 = TILE_SPACE after the first call.
; ---------------------------------------------------------------------------
.proc prompt_clear
    lda #TILE_SPACE
    ldx #PROMPT_COL
    ldy #PROMPT_ROW
    jsr PPU::update_tile_at_xy      ; A = 0 on success = TILE_SPACE
    ; A = 0 = TILE_SPACE — write 10 more spaces
    jsr PPU::update_next_byte
    jsr PPU::update_next_byte
    jsr PPU::update_next_byte
    jsr PPU::update_next_byte
    jsr PPU::update_next_byte
    jsr PPU::update_next_byte
    jsr PPU::update_next_byte
    jsr PPU::update_next_byte
    jsr PPU::update_next_byte
    jsr PPU::update_next_byte
    rts
.endproc

; ---------------------------------------------------------------------------
; Screens::show_paused
;   Queue "PAUSED" tiles into the nmt update buffer at row PAUSE_ROW,
;   cols PAUSE_COL … PAUSE_COL+5.  Row 1 is sky (normally $00 / blank),
;   so no background tile is disturbed.  Call before PPU::update in
;   loop_paused so the text appears on the very next rendered frame.
; ---------------------------------------------------------------------------
.export show_paused
.proc show_paused
    lda #TILE_P
    ldx #PAUSE_COL
    ldy #PAUSE_ROW
    jsr PPU::update_tile_at_xy
    lda #TILE_A  : jsr PPU::update_next_byte
    lda #TILE_U  : jsr PPU::update_next_byte
    lda #TILE_S  : jsr PPU::update_next_byte
    lda #TILE_E  : jsr PPU::update_next_byte
    lda #TILE_D  : jsr PPU::update_next_byte
    rts
.endproc

; ---------------------------------------------------------------------------
; Screens::hide_paused
;   Queue 6 blank tiles over "PAUSED" in the nmt update buffer.
;   Call after the pause loop exits, before the final PPU::update.
; ---------------------------------------------------------------------------
.export hide_paused
.proc hide_paused
    lda #TILE_SPACE
    ldx #PAUSE_COL
    ldy #PAUSE_ROW
    jsr PPU::update_tile_at_xy      ; A = 0 = TILE_SPACE on success
    jsr PPU::update_next_byte
    jsr PPU::update_next_byte
    jsr PPU::update_next_byte
    jsr PPU::update_next_byte
    jsr PPU::update_next_byte
    rts
.endproc

; ---------------------------------------------------------------------------
; Screens::loop_gameover
;   1. Turns off rendering.
;   2. Loads the game-over palette (black bg, red text).
;   3. Hides all 64 OAM sprites (sets Y = 255).
;   4. Clears the nametable.
;   5. Draws "GAME OVER" and three empty heart tiles directly.
;   6. Enables rendering and waits for START.
;   7. Calls World::init #0 (resets everything) then returns.
; ---------------------------------------------------------------------------
.export loop_gameover
.proc loop_gameover
    jsr PPU::render_off

    ; Load game-over palette
    ldx #0
    :
        lda gameover_palette, X
        sta PPU::palette_buffer, X
        inx
        cpx #32
        bcc :-

    ; Hide all sprites
    lda #255
    ldx #0
    :
        sta PPU::oam_buffer, X
        inx
        inx
        inx
        inx
        bne :-

    ; Clear nametable
    jsr PPU::clear_background

    ; -------------------------------------------------------------------
    ; Draw "GAME OVER" at (GAMEOVER_COL, GAMEOVER_ROW)
    ; G A M E   O V E R
    ; -------------------------------------------------------------------
    ldx #GAMEOVER_COL
    ldy #GAMEOVER_ROW
    jsr PPU::address_tile
    lda #TILE_G     : sta PPU::REG_DATA
    lda #TILE_A     : sta PPU::REG_DATA
    lda #TILE_M     : sta PPU::REG_DATA
    lda #TILE_E     : sta PPU::REG_DATA
    lda #TILE_SPACE : sta PPU::REG_DATA
    lda #TILE_O     : sta PPU::REG_DATA
    lda #TILE_V     : sta PPU::REG_DATA
    lda #TILE_E     : sta PPU::REG_DATA
    lda #TILE_R     : sta PPU::REG_DATA

    ; -------------------------------------------------------------------
    ; Draw three empty hearts at (GAMEOVER_HEARTS_COL, GAMEOVER_HEARTS_ROW)
    ; -------------------------------------------------------------------
    ldx #GAMEOVER_HEARTS_COL
    ldy #GAMEOVER_HEARTS_ROW
    jsr PPU::address_tile
    lda #TILE_HEART_EMPTY : sta PPU::REG_DATA
    lda #TILE_HEART_EMPTY : sta PPU::REG_DATA
    lda #TILE_HEART_EMPTY : sta PPU::REG_DATA

    ; Enable rendering
    lda #%10001000
    sta PPU::ctrl
    lda #%00011110
    sta PPU::mask

    ; Wait for START
    :
        jsr PPU::update
        jsr Joy::store_new_buttons
        and #Joy::BUTTON_START
        beq :-

    ; Restart world 0 — resets HP to 3, redraws background, spawns enemies
    lda #0
    jsr World::init
    rts
.endproc

.endscope ; Screens
