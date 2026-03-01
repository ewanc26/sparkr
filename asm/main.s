.fileopt    comment, "Sparkr main module"
.fileopt    author,  "Sparkr project"

; Assembler options
.linecont +

; imports
.include "locals.inc"
.include "ines.inc"
.include "ppu.inc"
.include "joy.inc"
.include "random.inc"
.include "player.inc"
.include "enemies.inc"
.include "world.inc"
.include "screens.inc"

.include "math_macros.inc"

;
; iNES header
;

.segment "HEADER"

INES_PRG_BANK_COUNT = 2 ; 16k PRG bank count
INES_CHR_BANK_COUNT = 1 ; 8k CHR bank count
INES_MAPPER         = 0 ; 0 = NROM (iNES standard mapper number)
INES_MIRROR         = 1 ; 0 = horizontal mirroring, 1 = vertical mirroring
INES_SRAM           = 0 ; 1 = battery backed SRAM at $6000-7FFF

INES_HEADER INES_PRG_BANK_COUNT, INES_CHR_BANK_COUNT, INES_MAPPER, INES_MIRROR, INES_SRAM

;
; CHR ROM
;

.segment "TILES"
.incbin "background.chr"   ; $0000-$0FFF background pattern table
.incbin "sprites.chr"      ; $1000-$1FFF sprite pattern table (Sparky)

;
; interrupt vectors
;

.segment "VECTORS"
.word PPU::nmi_buffered
.word reset
.word irq

;
; do-nothing irq
;

.segment "CODE"
irq:
    rti

;
; reset routine
;

.segment "CODE"
.proc reset
    sei       ; mask interrupts
    cld       ; disable decimal mode

    lda #0
    sta $4015 ; disable APU sound
    sta $4010 ; disable DMC IRQ
    lda #$40
    sta $4017 ; disable APU IRQ

    ldx #$FF
    txs       ; initialize stack

    ; clear all RAM to 0 (except $100 stack area)
    lda #0
    ldx #0
    :
        sta $0000, X
        sta $0200, X
        sta $0300, X
        sta $0400, X
        sta $0500, X
        sta $0600, X
        sta $0700, X
        inx
        bne :-

    jsr PPU::reset
    jmp main
    ; no rts
.endproc

;
; main
;
; Show the title screen, then start gameplay on world 0.
; Screens::loop_title waits for START and returns with rendering ON.
; World::init sets the game palette, draws the background, spawns enemies
; and resets the player — then we fall through into the game loop forever.
;

.segment "CODE"
.proc main
    jsr Screens::loop_title     ; draws title, waits for START
    lda #0
    jsr World::init             ; world 0: palette, bg, enemies, player
    jmp loop_gameplay
    ; no rts
.endproc


; ---------------------------------------------------------------------------
; handle_input_gameplay macro
;   Poll joypad once.  On a fresh START press, enter the pause loop.
; ---------------------------------------------------------------------------
.macro handle_input_gameplay
    jsr Joy::store_new_buttons
    and #Joy::BUTTON_START
    beq :+
        jsr loop_paused
    :
.endmacro


; ---------------------------------------------------------------------------
; loop_gameplay — the main per-frame game loop.
;
; Each iteration:
;   1. Poll input / enter pause on START
;   2. Player physics, input, animation
;   3. Enemy AI, movement, and collision detection vs. player
;   4. Death check: player_hp == 0 → game-over screen, restart world 0
;   5. World-clear check: all enemies dead → advance to next world
;   6. Render: player sprites, enemy sprites, HUD hearts
;   7. PPU::update — wait for NMI, push OAM/palette/nametable
; ---------------------------------------------------------------------------
.segment "CODE"
.proc loop_gameplay
    ; 1. Input (START triggers pause)
    handle_input_gameplay

    ; 2. Player
    jsr Player::tick

    ; 3. Enemies
    jsr Enemy::tick_all

    ; 4. Death check
    lda Player::player_hp
    bne @alive
    jsr Screens::loop_gameover  ; draws game-over, waits START, resets world 0
    jmp loop_gameplay
@alive:

    ; 5. World-clear check
    jsr Enemy::all_dead
    cmp #1
    bne @no_clear
    jsr World::next             ; advance to next world (wraps 2 → 0)
@no_clear:

    ; 6. Render
    jsr Player::render
    jsr Enemy::render_all
    jsr World::render_hud

    ; 7. Push to PPU
    jsr PPU::update

    jmp loop_gameplay
.endproc


; ---------------------------------------------------------------------------
; loop_paused — entered when START is pressed during gameplay.
;
;   • Writes "PAUSED" to the nametable (row 1, sky region — naturally blank).
;   • Spins calling PPU::update until START is pressed again.
;   • Erases "PAUSED" before returning so the sky row is clean.
; ---------------------------------------------------------------------------
.segment "CODE"
.proc loop_paused
    ; Write "PAUSED" into the nmt update buffer, then push it
    jsr Screens::show_paused
    jsr PPU::update

    ; Wait for START
    :
        jsr PPU::update
        jsr Joy::store_new_buttons
        and #Joy::BUTTON_START
        beq :-

    ; Erase "PAUSED" and push the blank tiles
    jsr Screens::hide_paused
    jsr PPU::update
    rts
.endproc
