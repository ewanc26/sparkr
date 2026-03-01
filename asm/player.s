; asm/player.s
;
; Sparkr — Sparky player mechanics module
;
; Implements movement, jumping, static dash, and overload attack for Sparky.
;
; PHYSICS MODEL
;   All positions and velocities are 16-bit fixed-point.
;   High byte = whole pixels, low byte = sub-pixel fraction (1/256 px).
;   Velocities are signed two's complement: positive Y = downward.
;
; MEMORY
;   14 zero-page bytes for persistent state + 4 draw temporaries.
;   OAM slots 0–3 are reserved for the player's 16×16 (2×2 tile) sprite.
;
; INTEGRATION
;   Call Player::init at level start.
;   Each game frame (in loop_gameplay):
;     1. Joy::store_new_buttons  (already done by handle_input_gameplay macro)
;     2. jsr Player::update
;     3. jsr Player::draw
;     4. jsr PPU::update

.fileopt comment, "Sparkr player mechanics"
.fileopt author,  "Sparkr project"

.include "locals.inc"
.include "ppu.inc"
.include "joy.inc"
.include "math_macros.inc"

.scope Player

; ===========================================================================
; Constants
; ===========================================================================

; ---------------------------------------------------------------------------
; Horizontal motion  (16-bit hi.lo = pixel.fraction)
; ---------------------------------------------------------------------------
WALK_ACCEL_LO   = $18   ; 0.094 px/frame² — applied each frame a direction is held
WALK_MAX_HI     = $01   ; \ max walk speed = $01_80 = 1.5 px/frame
WALK_MAX_LO     = $80   ; /
FRICTION_LO     = $10   ; 0.063 px/frame² — deceleration while grounded, no input

; ---------------------------------------------------------------------------
; Static Dash  (hold B → burst of speed)
; "1.5× speed" per README; we implement as a fixed dash_speed override.
; ---------------------------------------------------------------------------
DASH_SPD_HI     = $02   ; \ dash speed = $02_40 = 2.25 px/frame
DASH_SPD_LO     = $40   ; /    (negative left dash = $FD_C0)
DASH_FRAMES     = 14    ; frames the dash lasts before bleeding back to walk max

; ---------------------------------------------------------------------------
; Vertical motion
; ---------------------------------------------------------------------------
JUMP_VY_HI      = $FC   ; initial jump velocity = -4.0 px/frame (upward)
GRAVITY_LO      = $2C   ; 0.172 px/frame² — full gravity (A released or falling)
GRAVITY_HOLD_LO = $0A   ; 0.039 px/frame² — reduced gravity while A held & rising
                        ; holding A gives ~2.5× more air time (SMB-style variable jump)
VY_MAX_HI       = $04   ; terminal fall velocity = 4 px/frame

; ---------------------------------------------------------------------------
; Overload attack (throw sparks when Battery has been collected)
; ---------------------------------------------------------------------------
ATTACK_FRAMES   = 16

; ---------------------------------------------------------------------------
; Invincibility after being hurt
; ---------------------------------------------------------------------------
HURT_INV_FRAMES = 90   ; ~1.5 seconds at 60 fps
MAX_PLAYER_HP   = 3

; ---------------------------------------------------------------------------
; Animation
; ---------------------------------------------------------------------------
ANIM_RUN_PERIOD = 7     ; frames between run animation steps

; ---------------------------------------------------------------------------
; Screen layout
; Grass horizon is drawn at nametable tile row 15 → pixel Y = 120.
; Player sprite is 16 px tall; feet at Y = 120 means top of sprite at Y = 104.
; ---------------------------------------------------------------------------
FLOOR_Y         = 104
SCREEN_LEFT     = 8
SCREEN_RIGHT    = 232   ; 248 − 16 (sprite width) to keep Sparky fully on screen

; ---------------------------------------------------------------------------
; OAM slot assignments for the four player sprites (16×16 = 2×2 tiles).
; Each slot occupies 4 bytes in PPU::oam_buffer.
; ---------------------------------------------------------------------------
OAM_TL          = 0     ; top-left sprite
OAM_TR          = 1     ; top-right sprite
OAM_BL          = 2     ; bottom-left sprite
OAM_BR          = 3     ; bottom-right sprite

; ---------------------------------------------------------------------------
; Sprite tile indices in the sprite pattern table ($1000).
; Layout assumes tiles are arranged in a 16-wide grid:
;   Column 0–1 of each pair = left half, column 2–3 = right half (unused).
;   Row 0 tiles = $00–$0F, row 1 tiles = $10–$1F, …
;
;   $00 $01  idle TL/TR
;   $08 $09  idle BL/BR
;   $02 $03  run-0 TL/TR
;   $0A $0B  run-0 BL/BR
;   $04 $05  run-1 TL/TR
;   $0C $0D  run-1 BL/BR
;   $06 $07  jump/fall TL/TR
;   $0E $0F  jump/fall BL/BR
;   $10 $11  dash TL/TR
;   $18 $19  dash BL/BR
;   $12 $13  attack TL/TR
;   $1A $1B  attack BL/BR
; ---------------------------------------------------------------------------
TILE_IDLE_TL    = $00
TILE_IDLE_TR    = $01
TILE_IDLE_BL    = $08
TILE_IDLE_BR    = $09

TILE_RUN0_TL    = $02
TILE_RUN0_TR    = $03
TILE_RUN0_BL    = $0A
TILE_RUN0_BR    = $0B

TILE_RUN1_TL    = $04
TILE_RUN1_TR    = $05
TILE_RUN1_BL    = $0C
TILE_RUN1_BR    = $0D

TILE_JUMP_TL    = $06
TILE_JUMP_TR    = $07
TILE_JUMP_BL    = $0E
TILE_JUMP_BR    = $0F

TILE_DASH_TL    = $10
TILE_DASH_TR    = $11
TILE_DASH_BL    = $18
TILE_DASH_BR    = $19

TILE_ATCK_TL    = $12
TILE_ATCK_TR    = $13
TILE_ATCK_BL    = $1A
TILE_ATCK_BR    = $1B

; OAM attribute bits
PAL_DIM         = $00           ; sprite palette sp0 — normal Sparky
PAL_OVERLOAD    = $01           ; sprite palette sp1 — glowing Sparky
OAM_HFLIP       = %01000000     ; horizontal flip bit (mirrors left↔right)

; Clear-masks for flag bits  (AND these to clear a flag)
MASK_CLR_GROUNDED  = $FF ^ FLAG_GROUNDED   ; = %11111110
MASK_CLR_DASH_USED = $FF ^ FLAG_DASH_USED  ; = %11111011
MASK_CLR_FACING_L  = $FF ^ FLAG_FACING_L   ; = %11111101

; Re-export state/flag constants so they resolve within this scope too
FLAG_GROUNDED  = %00000001
FLAG_FACING_L  = %00000010
FLAG_DASH_USED = %00000100

STATE_IDLE     = 0
STATE_RUN      = 1
STATE_JUMP     = 2
STATE_FALL     = 3
STATE_DASH     = 4
STATE_ATTACK   = 5

; ===========================================================================
; Zero-page variables
; ===========================================================================
.segment "ZEROPAGE"

x_lo:           .res 1  ; X sub-pixel (unsigned 0–255)
x_hi:           .res 1  ; X screen pixel (left edge of 16-px sprite)
y_lo:           .res 1  ; Y sub-pixel
y_hi:           .res 1  ; Y screen pixel (top edge of 16-px sprite)
vx_lo:          .res 1  ; velocity-X sub-pixel (fraction, always treated unsigned)
vx_hi:          .res 1  ; velocity-X pixel (signed: $00=0, $01=+1, $FF=-1 …)
vy_lo:          .res 1  ; velocity-Y sub-pixel
vy_hi:          .res 1  ; velocity-Y pixel (signed: positive = downward)
flags:          .res 1  ; FLAG_GROUNDED | FLAG_FACING_L | FLAG_DASH_USED
state:          .res 1  ; current STATE_*
anim_frame:     .res 1  ; run cycle: 0 or 1
anim_timer:     .res 1  ; frames until next animation step
dash_timer:     .res 1  ; remaining dash frames (0 when not dashing)
attack_timer:   .res 1  ; remaining attack frames
overload:       .res 1  ; 0 = dim, 1 = overloaded (Battery collected)
player_hp:      .res 1  ; remaining hit points (0 = dead)
inv_timer:      .res 1  ; invincibility frames remaining after being hurt

; Draw-phase temporaries (computed fresh each frame in Player::draw)
draw_attr:      .res 1  ; OAM attribute byte (palette + flip)
draw_y_top:     .res 1  ; OAM Y for top sprite row
draw_y_bot:     .res 1  ; OAM Y for bottom sprite row
draw_x_r:       .res 1  ; OAM X for right sprite column

.exportzp x_lo, x_hi
.exportzp y_lo, y_hi
.exportzp vx_lo, vx_hi
.exportzp vy_lo, vy_hi
.exportzp flags, state, overload
.exportzp player_hp, inv_timer

; ===========================================================================
; CODE
; ===========================================================================
.segment "CODE"

; ---------------------------------------------------------------------------
; Player::init
;   Reset Sparky to starting position and clear all state.
;   Call once at the start of each level (after rendering is initialized).
; ---------------------------------------------------------------------------
.export init
.proc init
    ; Place Sparky horizontally centred, standing on the floor
    lda #120
    sta x_hi
    lda #0
    sta x_lo
    lda #FLOOR_Y
    sta y_hi
    lda #0
    sta y_lo

    ; Zero all velocities
    lda #0
    sta vx_lo
    sta vx_hi
    sta vy_lo
    sta vy_hi

    ; Ground Sparky, face right, dash ready
    lda #FLAG_GROUNDED
    sta flags
    lda #STATE_IDLE
    sta state

    ; Clear timers, mode, and damage state
    lda #0
    sta anim_frame
    sta anim_timer
    sta dash_timer
    sta attack_timer
    sta overload
    sta inv_timer
    lda #MAX_PLAYER_HP
    sta player_hp
    rts
.endproc

; ---------------------------------------------------------------------------
; Player::update
;   Master per-frame tick.  Call after Joy::store_new_buttons, before
;   Player::draw and PPU::update.
; ---------------------------------------------------------------------------
.export tick
.proc tick
    jsr tick_invincible
    jsr handle_input
    jsr apply_physics
    jsr check_floor
    jsr check_screen_bounds
    jsr update_anim
    rts
.endproc

; ---------------------------------------------------------------------------
; tick_invincible (internal)
;   Count down the post-hurt invincibility timer each frame.
; ---------------------------------------------------------------------------
.proc tick_invincible
    lda inv_timer
    beq @done
    dec inv_timer
@done:
    rts
.endproc

; ---------------------------------------------------------------------------
; Player::hurt
;   Called when the player collides with an enemy or projectile.
;   Decrements player_hp (floor 0) and starts the invincibility window.
; ---------------------------------------------------------------------------
.export hurt
.proc hurt
    lda player_hp
    beq @done           ; already dead — ignore further hits
    dec player_hp
    lda #HURT_INV_FRAMES
    sta inv_timer
@done:
    rts
.endproc

; ---------------------------------------------------------------------------
; handle_input  (internal)
;   Translate Joy::new_buttons_0 (just-pressed) and Joy::pad_0 (held)
;   into velocity changes and state transitions.
;
;   Priority: ATTACK (overload+A) > JUMP (A) > DASH (B) > LEFT/RIGHT
; ---------------------------------------------------------------------------
.proc handle_input
    ; -------------------------------------------------------------------
    ; SELECT — toggle overload mode (for testing; replace with Battery pickup)
    ; -------------------------------------------------------------------
    lda Joy::new_buttons_0
    and #Joy::BUTTON_SELECT
    beq @check_a
    lda overload
    eor #1                  ; toggle 0↔1
    sta overload

    ; -------------------------------------------------------------------
    ; A BUTTON — jump (normal) or spark attack (overload mode)
    ; -------------------------------------------------------------------
@check_a:
    lda Joy::new_buttons_0
    and #Joy::BUTTON_A
    beq @check_b            ; A not newly pressed this frame

    lda overload
    bne @do_attack          ; overloaded → A fires sparks

    ; --- JUMP: only while grounded ---
    lda flags
    and #FLAG_GROUNDED
    beq @check_b            ; airborne, no jump

    lda #JUMP_VY_HI
    sta vy_hi
    lda #0
    sta vy_lo
    lda flags
    and #MASK_CLR_GROUNDED  ; clear grounded flag
    sta flags
    lda #STATE_JUMP
    sta state
    jmp @check_b

@do_attack:
    ; --- SPARK ATTACK: ignore if already attacking ---
    lda state
    cmp #STATE_ATTACK
    beq @check_b
    lda #ATTACK_FRAMES
    sta attack_timer
    lda #STATE_ATTACK
    sta state

    ; -------------------------------------------------------------------
    ; B BUTTON — static dash (just pressed, dash not on cooldown)
    ; -------------------------------------------------------------------
@check_b:
    lda Joy::new_buttons_0
    and #Joy::BUTTON_B
    beq @check_lr

    lda flags
    and #FLAG_DASH_USED     ; cooldown active?
    bne @check_lr

    lda state               ; don't interrupt a spark attack
    cmp #STATE_ATTACK
    beq @check_lr

    ; Activate dash
    lda flags
    ora #FLAG_DASH_USED     ; mark dash as used until next landing
    sta flags
    lda #DASH_FRAMES
    sta dash_timer
    lda #STATE_DASH
    sta state

    ; -------------------------------------------------------------------
    ; LEFT / RIGHT — held for horizontal acceleration.
    ; Direction input is suppressed during dash and attack so those
    ; states can't be redirected mid-animation.
    ; -------------------------------------------------------------------
@check_lr:
    lda state
    cmp #STATE_DASH
    beq @done
    cmp #STATE_ATTACK
    beq @done

    ; Check RIGHT held
    lda Joy::pad_0
    and #Joy::BUTTON_RIGHT
    beq @check_left

    ; Accelerate rightward: vx += WALK_ACCEL_LO
    clc
    lda vx_lo
    adc #WALK_ACCEL_LO
    sta vx_lo
    lda vx_hi
    adc #0
    sta vx_hi

    ; Cap at positive WALK_MAX ($01_80)
    lda vx_hi
    bmi @face_right         ; vx is negative (decelerating from left) — no cap
    cmp #WALK_MAX_HI
    bcc @face_right         ; vx_hi < WALK_MAX_HI — safely below cap
    bne @clamp_right        ; vx_hi > WALK_MAX_HI — definitely over cap
    lda vx_lo               ; vx_hi == WALK_MAX_HI: check fraction
    cmp #WALK_MAX_LO
    bcc @face_right         ; fraction still within range
@clamp_right:
    lda #WALK_MAX_HI
    sta vx_hi
    lda #WALK_MAX_LO
    sta vx_lo
@face_right:
    lda flags
    and #MASK_CLR_FACING_L  ; clear FACING_L → face right
    sta flags
    jmp @done

@check_left:
    lda Joy::pad_0
    and #Joy::BUTTON_LEFT
    beq @done

    ; Accelerate leftward: vx -= WALK_ACCEL_LO
    sec
    lda vx_lo
    sbc #WALK_ACCEL_LO
    sta vx_lo
    lda vx_hi
    sbc #0
    sta vx_hi

    ; Cap at negative WALK_MAX ($FE_80 in 16-bit two's complement = −1.5 px/fr)
    lda vx_hi
    bpl @face_left          ; non-negative (decelerating from right) — no cap
    ; vx_hi is negative. Over-cap if vx_hi < $FE  or  (vx_hi=$FE and lo<$80).
    cmp #$FE
    bcc @clamp_left         ; vx_hi < $FE — over cap
    bne @face_left          ; vx_hi > $FE (e.g. $FF) — within range
    lda vx_lo               ; vx_hi == $FE: check fraction
    cmp #WALK_MAX_LO
    bcs @face_left          ; fraction >= $80 — within range
@clamp_left:
    lda #$FE
    sta vx_hi
    lda #WALK_MAX_LO
    sta vx_lo
@face_left:
    lda flags
    ora #FLAG_FACING_L
    sta flags

@done:
    rts
.endproc

; ---------------------------------------------------------------------------
; apply_physics  (internal)
;   Each frame: handle dash override → gravity → friction → integrate.
; ---------------------------------------------------------------------------
.proc apply_physics
    ; -------------------------------------------------------------------
    ; DASH — override vx with full dash speed in the current direction.
    ; Count down the dash timer; restore walk-max speed when it expires.
    ; -------------------------------------------------------------------
    lda state
    cmp #STATE_DASH
    bne @do_gravity

    dec dash_timer
    bne @set_dash_vel       ; timer still running: set dash velocity

    ; --- Dash expired: bleed back to walk-max speed ---
    lda flags
    and #FLAG_GROUNDED
    bne @end_dash_ground
    lda #STATE_FALL         ; was airborne at dash end
    sta state
    jmp @bleed_speed

@end_dash_ground:
    lda #STATE_RUN          ; grounded — check_floor will refine to IDLE if vx=0
    sta state

@bleed_speed:
    ; Clamp to walk-max in the current facing direction
    lda flags
    and #FLAG_FACING_L
    bne @bleed_left
    lda #WALK_MAX_HI        ; +walk_max
    sta vx_hi
    lda #WALK_MAX_LO
    sta vx_lo
    jmp @do_gravity
@bleed_left:
    lda #$FE                ; −walk_max ($FE_80)
    sta vx_hi
    lda #WALK_MAX_LO
    sta vx_lo
    jmp @do_gravity

@set_dash_vel:
    ; Overwrite vx with dash speed in facing direction
    lda flags
    and #FLAG_FACING_L
    bne @dash_left
    lda #DASH_SPD_HI        ; $02_40
    sta vx_hi
    lda #DASH_SPD_LO
    sta vx_lo
    jmp @do_gravity
@dash_left:
    lda #$FD                ; two's complement of $02_40 → $FD_C0
    sta vx_hi
    lda #($100 - DASH_SPD_LO)
    sta vx_lo
    ; fall through to @do_gravity

    ; -------------------------------------------------------------------
    ; GRAVITY — add downward acceleration while airborne.
    ;   If A is held AND Sparky is still rising (vy_hi < 0): reduced gravity
    ;   (SMB-style variable jump height — tap for short hop, hold for high arc)
    ;   Otherwise: full gravity.
    ; -------------------------------------------------------------------
@do_gravity:
    lda flags
    and #FLAG_GROUNDED
    bne @do_friction        ; grounded: skip gravity

    ; Choose gravity constant based on A held + still rising
    lda vy_hi
    bpl @full_gravity       ; vy >= 0 (falling): always full gravity
    lda Joy::pad_0          ; check if A is currently held
    and #Joy::BUTTON_A
    beq @full_gravity       ; A not held: full gravity
    ; A held and rising: apply reduced gravity
    clc
    lda vy_lo
    adc #GRAVITY_HOLD_LO
    sta vy_lo
    lda vy_hi
    adc #0
    sta vy_hi
    jmp @gravity_done
@full_gravity:
    clc
    lda vy_lo
    adc #GRAVITY_LO
    sta vy_lo
    lda vy_hi
    adc #0
    sta vy_hi
@gravity_done:
    ; Clamp at terminal velocity
    lda vy_hi
    cmp #VY_MAX_HI
    bcc @do_friction        ; below terminal, fine
    lda #VY_MAX_HI
    sta vy_hi
    lda #0
    sta vy_lo

    ; -------------------------------------------------------------------
    ; FRICTION — decelerate vx toward zero when all of these are true:
    ;   (a) grounded,  (b) not dashing,  (c) no left/right held.
    ; This is the "low friction momentum / slide when stopping" model.
    ; -------------------------------------------------------------------
@do_friction:
    lda flags
    and #FLAG_GROUNDED
    beq @integrate          ; airborne: no friction

    lda state
    cmp #STATE_DASH
    beq @integrate          ; dashing: no friction

    lda Joy::pad_0
    and #(Joy::BUTTON_LEFT | Joy::BUTTON_RIGHT)
    bne @integrate          ; direction held: player is actively driving

    ; Is vx already zero?
    lda vx_hi
    bne @frict_go
    lda vx_lo
    beq @integrate          ; vx == 0
@frict_go:
    lda vx_hi
    bmi @frict_neg

    ; --- Moving right: vx -= friction ---
    sec
    lda vx_lo
    sbc #FRICTION_LO
    sta vx_lo
    lda vx_hi
    sbc #0
    bpl @frict_store_pos    ; result non-negative: store it
    lda #0                  ; crossed zero: clamp
    sta vx_lo
    sta vx_hi
    jmp @integrate
@frict_store_pos:
    sta vx_hi
    jmp @integrate

@frict_neg:
    ; --- Moving left: vx += friction (moves toward zero) ---
    clc
    lda vx_lo
    adc #FRICTION_LO
    sta vx_lo
    lda vx_hi
    adc #0
    bmi @frict_store_neg    ; result still negative: store it
    lda #0                  ; crossed zero: clamp
    sta vx_lo
    sta vx_hi
    jmp @integrate
@frict_store_neg:
    sta vx_hi

    ; -------------------------------------------------------------------
    ; INTEGRATION — pos += velocity (signed 16-bit two's complement add)
    ; The carry from the low byte propagates into the signed high byte,
    ; so positive and negative velocities both work correctly with ADC.
    ; -------------------------------------------------------------------
@integrate:
    clc
    lda x_lo
    adc vx_lo
    sta x_lo
    lda x_hi
    adc vx_hi
    sta x_hi

    clc
    lda y_lo
    adc vy_lo
    sta y_lo
    lda y_hi
    adc vy_hi
    sta y_hi

    rts
.endproc

; ---------------------------------------------------------------------------
; check_floor  (internal)
;   Keep Sparky above FLOOR_Y; set / clear FLAG_GROUNDED; update state.
; ---------------------------------------------------------------------------
.proc check_floor
    lda y_hi
    cmp #FLOOR_Y
    bcc @airborne           ; y_hi < FLOOR_Y → still above floor

    ; Snap to floor and zero vertical velocity
    lda #FLOOR_Y
    sta y_hi
    lda #0
    sta y_lo
    sta vy_lo
    sta vy_hi

    ; Was Sparky airborne last frame?
    lda flags
    and #FLAG_GROUNDED
    bne @grounded_sync      ; already grounded: just sync run↔idle

    ; --- Landing ---
    lda flags
    ora #FLAG_GROUNDED
    and #MASK_CLR_DASH_USED ; dash recharges on landing
    sta flags

    ; Don't interrupt attack or (shouldn't happen) dash on landing
    lda state
    cmp #STATE_ATTACK
    beq @done
    cmp #STATE_DASH
    beq @done
    jmp @set_run_or_idle

@grounded_sync:
    ; Keep run↔idle in sync with vx while on the ground
    lda state
    cmp #STATE_DASH
    beq @done
    cmp #STATE_ATTACK
    beq @done

@set_run_or_idle:
    lda vx_hi
    bne @set_run
    lda vx_lo
    beq @set_idle
@set_run:
    lda #STATE_RUN
    sta state
    rts
@set_idle:
    lda #STATE_IDLE
    sta state
    rts

@airborne:
    ; Clear grounded flag
    lda flags
    and #MASK_CLR_GROUNDED
    sta flags

    ; Set JUMP or FALL based on vertical velocity direction
    lda state
    cmp #STATE_DASH
    beq @done
    cmp #STATE_ATTACK
    beq @done
    lda vy_hi
    bmi @is_jumping         ; vy negative → moving upward
    lda #STATE_FALL
    sta state
    rts
@is_jumping:
    lda #STATE_JUMP
    sta state
@done:
    rts
.endproc

; ---------------------------------------------------------------------------
; check_screen_bounds  (internal)
;   Clamp X to [SCREEN_LEFT, SCREEN_RIGHT] and zero vx if hitting an edge.
; ---------------------------------------------------------------------------
.proc check_screen_bounds
    lda x_hi
    cmp #SCREEN_LEFT
    bcs @check_right
    ; Hit left edge
    lda #SCREEN_LEFT
    sta x_hi
    lda #0
    sta x_lo
    sta vx_lo
    sta vx_hi
    rts
@check_right:
    cmp #SCREEN_RIGHT
    bcc @done
    ; Hit right edge
    lda #SCREEN_RIGHT
    sta x_hi
    lda #0
    sta x_lo
    sta vx_lo
    sta vx_hi
@done:
    rts
.endproc

; ---------------------------------------------------------------------------
; update_anim  (internal)
;   Advance animation timers; handle attack-state expiry.
; ---------------------------------------------------------------------------
.proc update_anim
    ; --- Tick attack timer ---
    lda state
    cmp #STATE_ATTACK
    bne @run_anim

    dec attack_timer
    bne @done               ; still attacking

    ; Attack expired: return to run / idle / fall
    lda flags
    and #FLAG_GROUNDED
    bne @post_attack_ground
    lda #STATE_FALL
    sta state
    rts
@post_attack_ground:
    lda vx_hi
    bne @set_run_post_atk
    lda vx_lo
    bne @set_run_post_atk
    lda #STATE_IDLE
    sta state
    rts
@set_run_post_atk:
    lda #STATE_RUN
    sta state
    rts

    ; --- Run animation: toggle anim_frame every ANIM_RUN_PERIOD frames ---
@run_anim:
    lda state
    cmp #STATE_RUN
    bne @reset_anim

    lda anim_timer
    beq @advance_frame
    dec anim_timer
    rts
@advance_frame:
    lda #ANIM_RUN_PERIOD
    sta anim_timer
    lda anim_frame
    eor #1                  ; toggle between 0 and 1
    sta anim_frame
    rts

    ; All non-run states hold frame 0
@reset_anim:
    lda #0
    sta anim_frame
    sta anim_timer
@done:
    rts
.endproc

; ---------------------------------------------------------------------------
; Player::draw
;   Write all four OAM sprite entries for Sparky's current frame.
;
;   Uses local_0–local_3 (from locals.inc) as tile index temporaries.
;   Uses draw_attr, draw_y_top, draw_y_bot, draw_x_r as coordinate temps.
;
;   Horizontal flip is implemented by:
;     (a) Setting OAM_HFLIP in the attribute byte for all four sprites.
;     (b) Swapping the left-column and right-column tile indices so the
;         sprite appears correctly mirrored.
; ---------------------------------------------------------------------------
.export render
.proc render
    ; -------------------------------------------------------------------
    ; Invincibility flash: hide Sparky every other 4-frame window while inv.
    ; -------------------------------------------------------------------
    lda inv_timer
    beq @not_invincible
    lda PPU::nmi_count
    and #$04
    beq @not_invincible
    ; Hide all four player sprite slots
    lda #255
    sta PPU::oam_buffer + (OAM_TL * 4)
    sta PPU::oam_buffer + (OAM_TR * 4)
    sta PPU::oam_buffer + (OAM_BL * 4)
    sta PPU::oam_buffer + (OAM_BR * 4)
    rts
@not_invincible:
    ; -------------------------------------------------------------------
    ; 1. Load the four tile indices for the current state into local_0..3
    ;    local_0 = TL, local_1 = TR, local_2 = BL, local_3 = BR
    ; -------------------------------------------------------------------
    lda state
    cmp #STATE_RUN
    bne @not_run
    lda anim_frame
    bne @run_f1
    ; Run frame 0
    lda #TILE_RUN0_TL
    sta local_0
    lda #TILE_RUN0_TR
    sta local_1
    lda #TILE_RUN0_BL
    sta local_2
    lda #TILE_RUN0_BR
    sta local_3
    jmp @tiles_done
@run_f1:
    lda #TILE_RUN1_TL
    sta local_0
    lda #TILE_RUN1_TR
    sta local_1
    lda #TILE_RUN1_BL
    sta local_2
    lda #TILE_RUN1_BR
    sta local_3
    jmp @tiles_done

@not_run:
    cmp #STATE_JUMP
    bne @not_jump
@load_jump:
    lda #TILE_JUMP_TL
    sta local_0
    lda #TILE_JUMP_TR
    sta local_1
    lda #TILE_JUMP_BL
    sta local_2
    lda #TILE_JUMP_BR
    sta local_3
    jmp @tiles_done

@not_jump:
    cmp #STATE_FALL
    beq @load_jump          ; fall reuses jump sprite

    cmp #STATE_DASH
    bne @not_dash
    lda #TILE_DASH_TL
    sta local_0
    lda #TILE_DASH_TR
    sta local_1
    lda #TILE_DASH_BL
    sta local_2
    lda #TILE_DASH_BR
    sta local_3
    jmp @tiles_done

@not_dash:
    cmp #STATE_ATTACK
    bne @load_idle
    lda #TILE_ATCK_TL
    sta local_0
    lda #TILE_ATCK_TR
    sta local_1
    lda #TILE_ATCK_BL
    sta local_2
    lda #TILE_ATCK_BR
    sta local_3
    jmp @tiles_done

@load_idle:
    lda #TILE_IDLE_TL
    sta local_0
    lda #TILE_IDLE_TR
    sta local_1
    lda #TILE_IDLE_BL
    sta local_2
    lda #TILE_IDLE_BR
    sta local_3

@tiles_done:
    ; -------------------------------------------------------------------
    ; 2. Compute OAM attribute byte.
    ;    Bits 1–0 = palette index (0 = dim, 1 = overload).
    ;    Bit  6   = horizontal flip when facing left.
    ; -------------------------------------------------------------------
    lda overload
    and #$01                ; palette index: 0 or 1
    sta draw_attr

    lda flags
    and #FLAG_FACING_L
    beq @facing_done        ; facing right: no flip, no tile swap

    ; Facing left: set h-flip bit in attribute
    lda draw_attr
    ora #OAM_HFLIP
    sta draw_attr

    ; Swap TL ↔ TR (so h-flipped left column shows what was the right)
    lda local_0
    pha
    lda local_1
    sta local_0
    pla
    sta local_1
    ; Swap BL ↔ BR
    lda local_2
    pha
    lda local_3
    sta local_2
    pla
    sta local_3

@facing_done:
    ; -------------------------------------------------------------------
    ; 3. Pre-compute screen coordinates.
    ;    NES OAM Y = (intended_pixel_row − 1): the hardware places sprites
    ;    one scanline below the written Y value.
    ; -------------------------------------------------------------------
    lda y_hi
    sec
    sbc #1
    sta draw_y_top          ; OAM Y for top-row sprites
    clc
    adc #8
    sta draw_y_bot          ; draw_y_top + 8 = OAM Y for bottom-row sprites

    lda x_hi
    clc
    adc #8
    sta draw_x_r            ; X for right-column sprites

    ; -------------------------------------------------------------------
    ; 4. Write all four OAM entries.
    ;    Each entry: [Y, tile, attributes, X]  (4 bytes each)
    ; -------------------------------------------------------------------

    ; Top-left (OAM slot 0)
    ldx #(OAM_TL * 4)
    lda draw_y_top
    sta PPU::oam_buffer, X
    inx
    lda local_0
    sta PPU::oam_buffer, X
    inx
    lda draw_attr
    sta PPU::oam_buffer, X
    inx
    lda x_hi
    sta PPU::oam_buffer, X

    ; Top-right (OAM slot 1)
    ldx #(OAM_TR * 4)
    lda draw_y_top
    sta PPU::oam_buffer, X
    inx
    lda local_1
    sta PPU::oam_buffer, X
    inx
    lda draw_attr
    sta PPU::oam_buffer, X
    inx
    lda draw_x_r
    sta PPU::oam_buffer, X

    ; Bottom-left (OAM slot 2)
    ldx #(OAM_BL * 4)
    lda draw_y_bot
    sta PPU::oam_buffer, X
    inx
    lda local_2
    sta PPU::oam_buffer, X
    inx
    lda draw_attr
    sta PPU::oam_buffer, X
    inx
    lda x_hi
    sta PPU::oam_buffer, X

    ; Bottom-right (OAM slot 3)
    ldx #(OAM_BR * 4)
    lda draw_y_bot
    sta PPU::oam_buffer, X
    inx
    lda local_3
    sta PPU::oam_buffer, X
    inx
    lda draw_attr
    sta PPU::oam_buffer, X
    inx
    lda draw_x_r
    sta PPU::oam_buffer, X

    rts
.endproc

.endscope ; Player
