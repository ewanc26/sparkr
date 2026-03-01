; asm/world.s
;
; Sparkr — World / level management module
;
; Defines three worlds with distinct palettes and enemy compositions:
;
;   World 0 "Grassland" — warm green tones; 2 Zappers + 1 Floater
;   World 1 "Stormcave" — dark blue/purple; 2 Floaters + 1 Shocker
;   World 2 "Electric Sky" — bright cyan/gold; 2 Zappers + 1 Floater + 1 Shocker
;
; World::init A sets up the palette, redraws the background, spawns enemies,
; and reinitialises the player.  It deliberately calls PPU::render_off first
; so it is safe to call both at startup and mid-game (on world transition).
;
; HUD hearts (OAM slots 9-11) are drawn by World::render_hud.

.fileopt comment, "Sparkr world/level management"
.fileopt author,  "Sparkr project"

.include "locals.inc"
.include "ppu.inc"
.include "joy.inc"
.include "random.inc"
.include "player.inc"
.include "enemies.inc"
.include "math_macros.inc"

.scope World

NUM_WORLDS = 3

; OAM slots for the three HUD hearts
OAM_HEART_0 = 9
OAM_HEART_1 = 10
OAM_HEART_2 = 11

TILE_HEART       = $27
TILE_HEART_EMPTY = $28
PAL_HEART        = $00    ; sp0 palette — same as Sparky dim (warm colours)

; Background tile parameters (reused from original main.s draw_grass)
GRASS_TOPPER_OFFSET = 1
N_GRASS_TOPPERS     = 4
GRASS_FILLER_OFFSET = 17
N_GRASS_FILLERS     = 1
GRASS_ACCENT_OFFSET = 18
N_GRASS_ACCENTS     = 3
ACCENT_PROB         = 25
HORIZON_Y           = 15

; BG base colour shared by all palettes (medium grey)
BG_COLOR = $21

; ===========================================================================
; Zero-page
; ===========================================================================
.segment "ZEROPAGE"

cur_world:  .res 1
.exportzp cur_world

; ===========================================================================
; Read-only world data tables
; ===========================================================================
.segment "RODATA"

; ---------------------------------------------------------------------------
; Palette tables
;
; Layout per world (9 bytes):
;   bytes 0-2: BG palette 0 colors 1,2,3
;   bytes 3-5: BG palette 1 colors 1,2,3
;   bytes 6-8: SP palette 2 (enemy) colors 1,2,3
; ---------------------------------------------------------------------------
world_palettes:

; World 0 — Grassland: earthy greens and browns
world_pal_0:
    .byte $0A,$1A,$2A   ; bg0: dark olive → medium green → light green
    .byte $07,$17,$27   ; bg1: darker teal → teal → light teal
    .byte $18,$28,$38   ; sp2 (enemy): dark orange → gold → bright yellow

; World 1 — Stormcave: deep blues, purple, and violet
world_pal_1:
    .byte $02,$12,$22   ; bg0: dark blue → medium blue → light blue
    .byte $04,$14,$24   ; bg1: dark violet → medium violet → light violet
    .byte $05,$15,$25   ; sp2 (enemy): dark green → medium → light teal

; World 2 — Electric Sky: bright cyan, gold, white
world_pal_2:
    .byte $28,$38,$30   ; bg0: orange-gold → bright yellow → white
    .byte $1B,$2B,$3B   ; bg1: teal-green → seafoam → near-white
    .byte $07,$17,$27   ; sp2 (enemy): teal tones

; ---------------------------------------------------------------------------
; Enemy spawn tables — terminated by ENEMY_TYPE_NONE ($00)
;
; Format: [type, x, y] per entry, $00 to end list
; ---------------------------------------------------------------------------

; World 0 spawns
world_0_spawns:
    .byte Enemy::ENEMY_TYPE_ZAPPER,  56, 112
    .byte Enemy::ENEMY_TYPE_ZAPPER, 184, 112
    .byte Enemy::ENEMY_TYPE_FLOATER, 128, 68
    .byte 0

; World 1 spawns
world_1_spawns:
    .byte Enemy::ENEMY_TYPE_FLOATER,  72, 56
    .byte Enemy::ENEMY_TYPE_FLOATER, 176, 72
    .byte Enemy::ENEMY_TYPE_SHOCKER, 128, 112
    .byte 0

; World 2 spawns (hardest — four enemies)
world_2_spawns:
    .byte Enemy::ENEMY_TYPE_ZAPPER,   48, 112
    .byte Enemy::ENEMY_TYPE_ZAPPER,  200, 112
    .byte Enemy::ENEMY_TYPE_FLOATER, 120,  56
    .byte Enemy::ENEMY_TYPE_SHOCKER,  96, 112
    .byte 0

; Pointer tables (lo/hi byte pairs for indirect indexing)
world_pal_lo:
    .byte <world_pal_0, <world_pal_1, <world_pal_2
world_pal_hi:
    .byte >world_pal_0, >world_pal_1, >world_pal_2

world_spawn_lo:
    .byte <world_0_spawns, <world_1_spawns, <world_2_spawns
world_spawn_hi:
    .byte >world_0_spawns, >world_1_spawns, >world_2_spawns

; ===========================================================================
; CODE
; ===========================================================================
.segment "CODE"

; ---------------------------------------------------------------------------
; World::init
;   A = world number (0, 1, or 2; clamped by modulo in World::next)
;   Turns off rendering, redraws the background, loads the world palette,
;   spawns enemies, and re-initialises the player.
; ---------------------------------------------------------------------------
.export init
.proc init
    sta cur_world

    ; --- Turn off PPU rendering so we can write tiles directly ----------
    jsr PPU::render_off

    ; --- Clear entire nametable ----------------------------------------
    jsr PPU::clear_background

    ; --- Draw tiled background -----------------------------------------
    Random_seed_crc16 #$FF00
    jsr draw_ground

    ; --- Load world palette into palette_buffer ------------------------
    jsr load_palette

    ; --- Re-enable rendering on the next PPU::update -------------------
    lda #%10001000
    sta PPU::ctrl
    lda #%00011110
    sta PPU::mask

    ; --- Initialise enemy system ---------------------------------------
    jsr Enemy::init_all
    jsr spawn_enemies

    ; --- Reset player position and state -------------------------------
    jsr Player::init

    rts
.endproc

; ---------------------------------------------------------------------------
; World::next
;   Advance to the next world (wraps 2 → 0) and call World::init.
; ---------------------------------------------------------------------------
.export next
.proc next
    lda cur_world
    clc
    adc #1
    cmp #NUM_WORLDS
    bcc :+
    lda #0              ; wrap back to world 0
    :
    jsr init
    rts
.endproc

; ---------------------------------------------------------------------------
; World::render_hud
;   Write OAM entries for the three HUD hearts based on Player::player_hp.
;   Call once per game frame (before PPU::update).
; ---------------------------------------------------------------------------
.export render_hud
.proc render_hud
    ; Heart 0 (leftmost) — OAM slot 9
    lda Player::player_hp
    cmp #1
    bcs @heart0_full
    lda #TILE_HEART_EMPTY
    jmp @write0
@heart0_full:
    lda #TILE_HEART
@write0:
    sta PPU::oam_buffer + (OAM_HEART_0 * 4) + 1    ; tile
    lda #7
    sta PPU::oam_buffer + (OAM_HEART_0 * 4)        ; Y (draw at row 8, minus 1 = 7)
    lda #PAL_HEART
    sta PPU::oam_buffer + (OAM_HEART_0 * 4) + 2    ; attr
    lda #8
    sta PPU::oam_buffer + (OAM_HEART_0 * 4) + 3    ; X

    ; Heart 1 — OAM slot 10
    lda Player::player_hp
    cmp #2
    bcs @heart1_full
    lda #TILE_HEART_EMPTY
    jmp @write1
@heart1_full:
    lda #TILE_HEART
@write1:
    sta PPU::oam_buffer + (OAM_HEART_1 * 4) + 1
    lda #7
    sta PPU::oam_buffer + (OAM_HEART_1 * 4)
    lda #PAL_HEART
    sta PPU::oam_buffer + (OAM_HEART_1 * 4) + 2
    lda #18
    sta PPU::oam_buffer + (OAM_HEART_1 * 4) + 3

    ; Heart 2 — OAM slot 11
    lda Player::player_hp
    cmp #3
    bcs @heart2_full
    lda #TILE_HEART_EMPTY
    jmp @write2
@heart2_full:
    lda #TILE_HEART
@write2:
    sta PPU::oam_buffer + (OAM_HEART_2 * 4) + 1
    lda #7
    sta PPU::oam_buffer + (OAM_HEART_2 * 4)
    lda #PAL_HEART
    sta PPU::oam_buffer + (OAM_HEART_2 * 4) + 2
    lda #28
    sta PPU::oam_buffer + (OAM_HEART_2 * 4) + 3

    rts
.endproc

; ===========================================================================
; Internal helpers
; ===========================================================================

; ---------------------------------------------------------------------------
; load_palette
;   Copies palette data for cur_world into PPU::palette_buffer.
;   We set all 32 bytes:
;     [0]    = BG_COLOR (shared background colour for all palettes)
;     [1..3] = BG palette 0 colours 1-3  (from world data)
;     [4]    = BG_COLOR
;     [5..7] = BG palette 1 colours 1-3  (from world data)
;     [8..15]= BG palettes 2 & 3 = copy of palette 0/1 (simple approach)
;     [16..19]= SP0 Sparky dim      (fixed)
;     [20..23]= SP1 Sparky overload (fixed)
;     [24..27]= SP2 enemy palette   (from world data)
;     [28..31]= SP3 Shocker palette (fixed dark red / magenta)
;
;   Uses addr_0 as pointer to the world's 9-byte palette entry.
; ---------------------------------------------------------------------------
.proc load_palette
    ; Set addr_0 to world palette data pointer
    ldy cur_world
    lda world_pal_lo, Y
    sta addr_0
    lda world_pal_hi, Y
    sta addr_0 + 1

    ; BG palette 0
    lda #BG_COLOR
    sta PPU::palette_buffer + 0
    ldy #0
    lda (addr_0), Y
    sta PPU::palette_buffer + 1
    iny
    lda (addr_0), Y
    sta PPU::palette_buffer + 2
    iny
    lda (addr_0), Y
    sta PPU::palette_buffer + 3

    ; BG palette 1
    lda #BG_COLOR
    sta PPU::palette_buffer + 4
    iny                     ; Y = 3
    lda (addr_0), Y
    sta PPU::palette_buffer + 5
    iny
    lda (addr_0), Y
    sta PPU::palette_buffer + 6
    iny
    lda (addr_0), Y
    sta PPU::palette_buffer + 7

    ; BG palettes 2 & 3 mirror palette 0 & 1 (simple)
    ldx #0
    :
        lda PPU::palette_buffer, X
        sta PPU::palette_buffer + 8, X
        sta PPU::palette_buffer + 12, X
        inx
        cpx #4
        bcc :-

    ; SP0 — Sparky dim: rust → golden → bright yellow
    lda #BG_COLOR
    sta PPU::palette_buffer + 16
    lda #$16
    sta PPU::palette_buffer + 17
    lda #$28
    sta PPU::palette_buffer + 18
    lda #$38
    sta PPU::palette_buffer + 19

    ; SP1 — Sparky overload: dark blue → cyan → white
    lda #BG_COLOR
    sta PPU::palette_buffer + 20
    lda #$02
    sta PPU::palette_buffer + 21
    lda #$21
    sta PPU::palette_buffer + 22
    lda #$30
    sta PPU::palette_buffer + 23

    ; SP2 — Enemy (Zapper/Floater): from world data bytes 6-8
    lda #BG_COLOR
    sta PPU::palette_buffer + 24
    ldy #6
    lda (addr_0), Y
    sta PPU::palette_buffer + 25
    iny
    lda (addr_0), Y
    sta PPU::palette_buffer + 26
    iny
    lda (addr_0), Y
    sta PPU::palette_buffer + 27

    ; SP3 — Shocker: deep red tones (fixed across all worlds)
    lda #BG_COLOR
    sta PPU::palette_buffer + 28
    lda #$16
    sta PPU::palette_buffer + 29
    lda #$26
    sta PPU::palette_buffer + 30
    lda #$36
    sta PPU::palette_buffer + 31

    rts
.endproc

; ---------------------------------------------------------------------------
; draw_ground
;   Draws the tiled grass background while rendering is off.
;   Identical logic to the original draw_grass in main.s, now centralised.
; ---------------------------------------------------------------------------
.proc draw_ground
    ; Topper row: HORIZON_Y filled with randomly chosen grass topper tiles
    ldx #0
    ldy #HORIZON_Y
    jsr PPU::address_tile
    ldy #32
    :
        rand8_between GRASS_TOPPER_OFFSET, GRASS_TOPPER_OFFSET + N_GRASS_TOPPERS
        sta PPU::REG_DATA
        dey
        bne :-

    ; Fill rows below the horizon with filler and accent tiles
    lda #(30 - HORIZON_Y - 1)
    cur_row = local_0
    sta cur_row
    :
        ldy #32
        :
            jsr Random::random_crc16
            cmp #ACCENT_PROB
            bcs filler
            mathmac_mod8 #N_GRASS_ACCENTS
            clc
            adc #GRASS_ACCENT_OFFSET
            sta PPU::REG_DATA
            jmp nextcol
        filler:
            mathmac_mod8 #N_GRASS_FILLERS
            clc
            adc #GRASS_FILLER_OFFSET
            sta PPU::REG_DATA
        nextcol:
            dey
            bne :--
        dec cur_row
        bne :---

    rts
.endproc

; ---------------------------------------------------------------------------
; spawn_enemies
;   Reads the spawn table for cur_world and calls Enemy::spawn for each entry.
;   Uses addr_0 as the read pointer, local_0/local_1 for spawn args.
; ---------------------------------------------------------------------------
.proc spawn_enemies
    ; Point addr_0 at the spawn table for this world
    ldy cur_world
    lda world_spawn_lo, Y
    sta addr_0
    lda world_spawn_hi, Y
    sta addr_0 + 1

    ldx #0              ; slot index
    ldy #0              ; byte offset into spawn table

@loop:
    lda (addr_0), Y
    beq @done           ; type == 0 → end of list
    iny
    sta local_2         ; save type temporarily

    lda (addr_0), Y
    iny
    sta local_0         ; X position for Enemy::spawn

    lda (addr_0), Y
    iny
    sta local_1         ; Y position for Enemy::spawn

    lda local_2
    jsr Enemy::spawn    ; X = slot, A = type, local_0 = x, local_1 = y

    inx
    cpx #Enemy::MAX_ENEMIES
    bcc @loop           ; keep going if slots remain

@done:
    rts
.endproc

.endscope ; World
