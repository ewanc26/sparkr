; asm/enemies.s
;
; Sparkr — Enemy system module
;
; Implements three enemy types:
;   ZAPPER  — ground-walking spark ball; bounces at screen edges. HP 2.
;   FLOATER — airborne ghost that bobs vertically and drifts left/right. HP 1.
;   SHOCKER — stationary electric turret; fires a spark projectile. HP 3.
;
; Also manages a single on-screen projectile (fired by Shocker).
;
; MEMORY
;   Enemy data lives in the RAM segment (struct-of-arrays, indexed by X).
;   Projectile state lives in the RAM segment.
;   No zero-page use by this module.
;
; INTEGRATION (per frame, inside loop_gameplay)
;   1. jsr Enemy::tick_all     ; AI + physics + collision vs player
;   2. jsr Enemy::render_all   ; write OAM slots 4-8
;
; OAM SLOT MAP
;   0-3 : Player (16×16, 4 entries)
;   4   : Enemy 0
;   5   : Enemy 1
;   6   : Enemy 2
;   7   : Enemy 3
;   8   : Projectile
;   9-11: HUD hearts (managed by world.s)

.fileopt comment, "Sparkr enemy system"
.fileopt author,  "Sparkr project"

.include "locals.inc"
.include "ppu.inc"
.include "joy.inc"
.include "random.inc"
.include "player.inc"
.include "math_macros.inc"

.scope Enemy

; ===========================================================================
; Constants
; ===========================================================================

MAX_ENEMIES       = 4

ENEMY_TYPE_NONE    = 0
ENEMY_TYPE_ZAPPER  = 1
ENEMY_TYPE_FLOATER = 2
ENEMY_TYPE_SHOCKER = 3

; Screen bounds for enemy movement (8-px wide enemy sprites)
ENEMY_SCREEN_LEFT  = 8
ENEMY_SCREEN_RIGHT = 240   ; 248 - 8

; Floor Y for ground enemies (same as player FLOOR_Y, top of 8-px sprite)
ENEMY_FLOOR_Y      = 112   ; player floor + 8 (enemy is 8px tall, bottom aligns)

; Zapper parameters
ZAPPER_SPEED       = 1     ; px / frame

; Floater parameters
FLOATER_MIN_Y      = 48    ; highest Y the floater reaches
FLOATER_MAX_Y      = 88    ; lowest Y (above floor)
FLOATER_SCREEN_RIGHT = 232

; Shocker parameters
SHOCKER_FIRE_PERIOD = 90   ; frames between shots

; Projectile
PROJ_SPEED         = 2     ; px / frame (added as unsigned: $02 or $FE)
PROJ_SPEED_NEG     = $FE   ; two's-complement of -PROJ_SPEED for byte add

; Invincibility duration after player is hit
INV_FRAMES         = 90

; Sprite tile indices in the sprite CHR bank ($1000-$1FFF)
TILE_ZAPPER_0   = $20
TILE_ZAPPER_1   = $21
TILE_FLOATER_0  = $22
TILE_FLOATER_1  = $23
TILE_SHOCKER_0  = $24
TILE_SHOCKER_1  = $25
TILE_PROJECTILE = $26

; OAM slot for each enemy and the projectile
OAM_ENEMY_BASE  = 4        ; enemy 0 in OAM slot 4
OAM_PROJECTILE  = 8        ; projectile in OAM slot 8

; Sprite palette index for enemy OAM attribute byte
PAL_ENEMY_A  = $02         ; sp2 — Zapper / Floater
PAL_ENEMY_B  = $03         ; sp3 — Shocker
PAL_PROJ     = $01         ; sp1 — projectile (overload-style blue)

; ===========================================================================
; RAM data — struct-of-arrays (MAX_ENEMIES = 4 entries each)
; ===========================================================================
.segment "RAM"

enemy_x:       .res MAX_ENEMIES   ; screen X (pixel, unsigned)
enemy_y:       .res MAX_ENEMIES   ; screen Y (pixel, unsigned)
enemy_vx:      .res MAX_ENEMIES   ; velocity X: $01=+1, $FF=-1, $00=0
enemy_type:    .res MAX_ENEMIES   ; ENEMY_TYPE_* (0 = inactive)
enemy_timer:   .res MAX_ENEMIES   ; general timer (Floater: phase, Shocker: countdown)
enemy_hp:      .res MAX_ENEMIES   ; hit points remaining

; Single projectile (only one active at a time)
proj_x:        .res 1
proj_y:        .res 1
proj_vx:       .res 1             ; $02 or $FE
proj_active:   .res 1             ; 0 = inactive

.export enemy_x, enemy_y, enemy_vx, enemy_type, enemy_timer, enemy_hp
.export proj_x, proj_y, proj_vx, proj_active

; ===========================================================================
; CODE
; ===========================================================================
.segment "CODE"

; ---------------------------------------------------------------------------
; Enemy::init_all
;   Zero all enemy slots and the projectile.  Call at level start.
; ---------------------------------------------------------------------------
.export init_all
.proc init_all
    ldx #(MAX_ENEMIES - 1)
    lda #0
@loop:
    sta enemy_x, X
    sta enemy_y, X
    sta enemy_vx, X
    sta enemy_type, X
    sta enemy_timer, X
    sta enemy_hp, X
    dex
    bpl @loop
    sta proj_active
    sta proj_x
    sta proj_y
    sta proj_vx
    rts
.endproc

; ---------------------------------------------------------------------------
; Enemy::spawn
;   Initialise one enemy slot.
;   Input:
;     X  = slot (0-3)
;     A  = type (ENEMY_TYPE_*)
;     local_0 = initial X position
;     local_1 = initial Y position
;   Clobbers A.
; ---------------------------------------------------------------------------
.export spawn
.proc spawn
    sta enemy_type, X

    lda local_0
    sta enemy_x, X
    lda local_1
    sta enemy_y, X

    ; Set type-specific defaults
    lda enemy_type, X
    cmp #ENEMY_TYPE_ZAPPER
    bne @chk_float

    ; Zapper: start moving right, 2 HP
    lda #$01
    sta enemy_vx, X
    lda #0
    sta enemy_timer, X
    lda #2
    sta enemy_hp, X
    rts

@chk_float:
    cmp #ENEMY_TYPE_FLOATER
    bne @is_shocker

    ; Floater: start moving right, 1 HP, timer=0
    lda #$01
    sta enemy_vx, X
    lda #0
    sta enemy_timer, X
    lda #1
    sta enemy_hp, X
    rts

@is_shocker:
    ; Shocker: stationary, 3 HP, fire towards player at spawn time
    lda #0
    sta enemy_vx, X       ; doesn't move
    lda #(SHOCKER_FIRE_PERIOD / 2)
    sta enemy_timer, X    ; first shot after half the period
    lda #3
    sta enemy_hp, X
    ; Determine initial fire direction from current player position
    lda Player::x_hi
    cmp enemy_x, X
    bcs @fire_right       ; player is to the right
    lda #$FF              ; store $FF = fire left
    sta enemy_vx, X
    rts
@fire_right:
    lda #$01
    sta enemy_vx, X
    rts
.endproc

; ---------------------------------------------------------------------------
; Enemy::tick_all
;   Update all active enemy slots, tick projectile, then check collisions.
;   Call once per game frame.
; ---------------------------------------------------------------------------
.export tick_all
.proc tick_all
    ldx #0
@loop:
    lda enemy_type, X
    beq @next
    cmp #ENEMY_TYPE_ZAPPER
    bne @chk_float
    jsr tick_zapper
    jmp @next
@chk_float:
    cmp #ENEMY_TYPE_FLOATER
    bne @is_shocker
    jsr tick_floater
    jmp @next
@is_shocker:
    jsr tick_shocker
@next:
    inx
    cpx #MAX_ENEMIES
    bcc @loop

    jsr tick_projectile
    jsr check_collisions
    rts
.endproc

; ---------------------------------------------------------------------------
; Enemy::render_all
;   Write OAM entries for every enemy slot and the projectile.
;   Inactive slots are hidden (Y = 255).  Call once per game frame.
; ---------------------------------------------------------------------------
.export render_all
.proc render_all
    ldx #0
@loop:
    jsr render_one
    inx
    cpx #MAX_ENEMIES
    bcc @loop
    jsr render_projectile
    rts
.endproc

; ---------------------------------------------------------------------------
; Enemy::all_dead
;   Returns A = 1 if all enemy slots are inactive AND projectile is inactive.
;   Returns A = 0 otherwise.
; ---------------------------------------------------------------------------
.export all_dead
.proc all_dead
    ldx #0
@loop:
    lda enemy_type, X
    bne @no
    inx
    cpx #MAX_ENEMIES
    bcc @loop
    lda proj_active
    bne @no
    lda #1
    rts
@no:
    lda #0
    rts
.endproc

; ===========================================================================
; Internal helper subroutines — all preserve X (the current slot index)
; ===========================================================================

; ---------------------------------------------------------------------------
; tick_zapper
;   Moves the Zapper one pixel left or right.  Bounces at screen edges.
;   Preserves X.
; ---------------------------------------------------------------------------
.proc tick_zapper
    lda enemy_x, X
    clc
    adc enemy_vx, X     ; unsigned add: $01 = +1, $FF = -1 (wraps correctly)
    ; Bounds check
    cmp #(ENEMY_SCREEN_RIGHT + 1)
    bcs @at_right
    cmp #ENEMY_SCREEN_LEFT
    bcc @at_left
    sta enemy_x, X
    rts

@at_right:
    lda #ENEMY_SCREEN_RIGHT
    sta enemy_x, X
    lda #$FF            ; reverse: now face left
    sta enemy_vx, X
    rts

@at_left:
    lda #ENEMY_SCREEN_LEFT
    sta enemy_x, X
    lda #$01            ; reverse: now face right
    sta enemy_vx, X
    rts
.endproc

; ---------------------------------------------------------------------------
; tick_floater
;   Bobs vertically (uses enemy_timer as phase) and drifts horizontally at
;   half speed.  Bounces at screen edges.  Preserves X.
; ---------------------------------------------------------------------------
.proc tick_floater
    inc enemy_timer, X

    ; Bob: every 8 frames, move 1 px up or down depending on timer bit 6
    lda enemy_timer, X
    and #$07
    bne @horiz

    lda enemy_timer, X
    and #$40            ; bit 6 toggles every 64 frames
    beq @bob_up

    ; Bob down
    lda enemy_y, X
    cmp #FLOATER_MAX_Y
    bcs @horiz          ; already at floor ceiling, stop going further down
    clc
    adc #1
    sta enemy_y, X
    jmp @horiz

@bob_up:
    lda enemy_y, X
    cmp #(FLOATER_MIN_Y + 1)
    bcc @horiz          ; already at top limit
    sec
    sbc #1
    sta enemy_y, X

    ; Horizontal movement: every 4 frames
@horiz:
    lda enemy_timer, X
    and #$03
    bne @done

    lda enemy_x, X
    clc
    adc enemy_vx, X
    cmp #(FLOATER_SCREEN_RIGHT + 1)
    bcs @at_right
    cmp #ENEMY_SCREEN_LEFT
    bcc @at_left
    sta enemy_x, X
    rts

@at_right:
    lda #FLOATER_SCREEN_RIGHT
    sta enemy_x, X
    lda #$FF
    sta enemy_vx, X
    rts

@at_left:
    lda #ENEMY_SCREEN_LEFT
    sta enemy_x, X
    lda #$01
    sta enemy_vx, X
@done:
    rts
.endproc

; ---------------------------------------------------------------------------
; tick_shocker
;   Counts down fire timer.  When it reaches zero, fires a projectile
;   in the direction stored in enemy_vx (set at spawn or on reset).
;   Preserves X.
; ---------------------------------------------------------------------------
.proc tick_shocker
    lda enemy_timer, X
    beq @fire
    dec enemy_timer, X
    rts

@fire:
    ; Reset timer
    lda #SHOCKER_FIRE_PERIOD
    sta enemy_timer, X

    ; Don't fire if a projectile is already active
    lda proj_active
    bne @done

    ; Spawn projectile
    lda #1
    sta proj_active

    ; Offset the spawn point to the side of the Shocker sprite
    lda enemy_vx, X
    cmp #$01
    bne @left_proj

    ; Fire right: origin at right edge of sprite
    lda enemy_x, X
    clc
    adc #8
    sta proj_x
    lda #PROJ_SPEED
    sta proj_vx
    jmp @proj_y

@left_proj:
    ; Fire left: origin at left edge of sprite (subtract 8)
    lda enemy_x, X
    sec
    sbc #8
    sta proj_x
    lda #PROJ_SPEED_NEG
    sta proj_vx

@proj_y:
    lda enemy_y, X
    clc
    adc #4              ; vertical centre of sprite
    sta proj_y

@done:
    rts
.endproc

; ---------------------------------------------------------------------------
; tick_projectile
;   Moves the active projectile; deactivates it if it leaves the screen.
; ---------------------------------------------------------------------------
.proc tick_projectile
    lda proj_active
    beq @done

    lda proj_x
    clc
    adc proj_vx
    ; Off left edge?
    cmp #ENEMY_SCREEN_LEFT
    bcc @deactivate
    ; Off right edge?
    cmp #(ENEMY_SCREEN_RIGHT + 8)
    bcs @deactivate
    sta proj_x
    rts

@deactivate:
    lda #0
    sta proj_active
@done:
    rts
.endproc

; ---------------------------------------------------------------------------
; check_collisions
;   1. If player not invincible: check each enemy & projectile vs player.
;      First hit calls Player::hurt (sets invincibility) and stops checking.
;   2. If player is attacking: check each enemy vs player hitbox.
;      Enemies that overlap take 1 damage; at 0 HP they are removed.
; ---------------------------------------------------------------------------
.proc check_collisions
    ; -----------------------------------------------------------------------
    ; Part 1 — enemies and projectile hurting the player
    ; -----------------------------------------------------------------------
    lda Player::inv_timer
    bne @check_attack       ; invincible — skip

    ldx #0
@hurt_loop:
    lda enemy_type, X
    beq @hurt_next          ; inactive slot

    ; AABB: enemy (8×8) at (ex, ey) vs player (16×16) at (px, py)
    ; No X overlap if: ex+7 < px  OR  px+15 < ex
    ; No Y overlap if: ey+7 < py  OR  py+15 < ey

    lda enemy_x, X
    clc
    adc #7
    cmp Player::x_hi        ; ex+7 < px?
    bcc @hurt_next

    lda Player::x_hi
    clc
    adc #15
    cmp enemy_x, X          ; px+15 < ex?
    bcc @hurt_next

    lda enemy_y, X
    clc
    adc #7
    cmp Player::y_hi        ; ey+7 < py?
    bcc @hurt_next

    lda Player::y_hi
    clc
    adc #15
    cmp enemy_y, X          ; py+15 < ey?
    bcc @hurt_next

    ; Overlap — hurt the player
    jsr Player::hurt
    jmp @check_attack       ; invincibility now set; skip rest of hurt checks

@hurt_next:
    inx
    cpx #MAX_ENEMIES
    bcc @hurt_loop

    ; Check projectile vs player
    lda proj_active
    beq @check_attack

    lda proj_x
    clc
    adc #7
    cmp Player::x_hi
    bcc @check_attack

    lda Player::x_hi
    clc
    adc #15
    cmp proj_x
    bcc @check_attack

    lda proj_y
    clc
    adc #7
    cmp Player::y_hi
    bcc @check_attack

    lda Player::y_hi
    clc
    adc #15
    cmp proj_y
    bcc @check_attack

    ; Projectile hit the player
    jsr Player::hurt
    lda #0
    sta proj_active

    ; -----------------------------------------------------------------------
    ; Part 2 — player attack hitting enemies
    ; -----------------------------------------------------------------------
@check_attack:
    lda Player::state
    cmp #Player::STATE_ATTACK
    bne @done

    ldx #0
@atk_loop:
    lda enemy_type, X
    beq @atk_next

    lda enemy_x, X
    clc
    adc #7
    cmp Player::x_hi
    bcc @atk_next

    lda Player::x_hi
    clc
    adc #15
    cmp enemy_x, X
    bcc @atk_next

    lda enemy_y, X
    clc
    adc #7
    cmp Player::y_hi
    bcc @atk_next

    lda Player::y_hi
    clc
    adc #15
    cmp enemy_y, X
    bcc @atk_next

    ; Attack connects
    lda enemy_hp, X
    beq @atk_next           ; already dying (shouldn't normally happen)
    dec enemy_hp, X
    bne @atk_next           ; still alive

    ; Enemy dies
    lda #ENEMY_TYPE_NONE
    sta enemy_type, X

@atk_next:
    inx
    cpx #MAX_ENEMIES
    bcc @atk_loop

@done:
    rts
.endproc

; ---------------------------------------------------------------------------
; render_one
;   Write one OAM entry for enemy slot X.  Inactive enemies are hidden.
;   Uses local_0 (saved slot), local_1 (OAM byte offset),
;        local_2 (tile), local_3 (attribute).
;   Preserves X.
; ---------------------------------------------------------------------------
.proc render_one
    stx local_0         ; save slot

    ; OAM byte offset = (OAM_ENEMY_BASE + slot) * 4
    txa
    clc
    adc #OAM_ENEMY_BASE
    asl
    asl                 ; * 4
    sta local_1         ; local_1 = OAM byte offset

    lda enemy_type, X
    bne @active

    ; Inactive: hide by setting Y = 255
    ldy local_1
    lda #255
    sta PPU::oam_buffer, Y
    ldx local_0
    rts

@active:
    ; ---- Select tile (8-frame, 16-frame, 32-frame animation periods) ----
    cmp #ENEMY_TYPE_ZAPPER
    bne @chk_float

    lda PPU::nmi_count
    and #$08
    beq @z0
    lda #TILE_ZAPPER_1
    jmp @tile_done
@z0:
    lda #TILE_ZAPPER_0
    jmp @tile_done

@chk_float:
    cmp #ENEMY_TYPE_FLOATER
    bne @is_shocker

    lda PPU::nmi_count
    and #$10
    beq @f0
    lda #TILE_FLOATER_1
    jmp @tile_done
@f0:
    lda #TILE_FLOATER_0
    jmp @tile_done

@is_shocker:
    lda PPU::nmi_count
    and #$20
    beq @s0
    lda #TILE_SHOCKER_1
    jmp @tile_done
@s0:
    lda #TILE_SHOCKER_0

@tile_done:
    sta local_2         ; save tile index

    ; ---- Select palette: Shocker = sp3, others = sp2 ----
    cmp #TILE_SHOCKER_0
    bcc @use_sp2        ; tile < $24 → Zapper or Floater → sp2
    lda #PAL_ENEMY_B
    jmp @pal_done
@use_sp2:
    lda #PAL_ENEMY_A
@pal_done:
    sta local_3         ; save attribute byte

    ; ---- Write OAM entry ----
    ldx local_0
    ldy local_1

    ; Byte 0: Y (hardware draws sprite one scanline below the stored value)
    lda enemy_y, X
    sec
    sbc #1
    sta PPU::oam_buffer, Y
    iny

    ; Byte 1: tile index
    lda local_2
    sta PPU::oam_buffer, Y
    iny

    ; Byte 2: attributes (palette)
    lda local_3
    sta PPU::oam_buffer, Y
    iny

    ; Byte 3: X
    lda enemy_x, X
    sta PPU::oam_buffer, Y

    ldx local_0
    rts
.endproc

; ---------------------------------------------------------------------------
; render_projectile
;   Write or hide OAM slot OAM_PROJECTILE based on proj_active.
; ---------------------------------------------------------------------------
.proc render_projectile
    lda proj_active
    bne @active

    ; Hide
    lda #255
    sta PPU::oam_buffer + (OAM_PROJECTILE * 4)
    rts

@active:
    lda proj_y
    sec
    sbc #1
    sta PPU::oam_buffer + (OAM_PROJECTILE * 4)

    lda #TILE_PROJECTILE
    sta PPU::oam_buffer + (OAM_PROJECTILE * 4) + 1

    lda #PAL_PROJ
    sta PPU::oam_buffer + (OAM_PROJECTILE * 4) + 2

    lda proj_x
    sta PPU::oam_buffer + (OAM_PROJECTILE * 4) + 3
    rts
.endproc

.endscope ; Enemy
