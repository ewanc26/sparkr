; inc/player.inc
; Public interface for the Sparkr player module.

.ifndef Player_included
Player_included = 1

.scope Player

    ; -----------------------------------------------------------------------
    ; Exported zero-page variables
    ; -----------------------------------------------------------------------
    .importzp x_lo, x_hi        ; screen X (pixel.fraction)
    .importzp y_lo, y_hi        ; screen Y of top edge (pixel.fraction)
    .importzp vx_lo, vx_hi      ; horizontal velocity (signed 16-bit fixed-pt)
    .importzp vy_lo, vy_hi      ; vertical velocity   (signed 16-bit fixed-pt)
    .importzp flags             ; FLAG_* bitmask
    .importzp state             ; current STATE_*
    .importzp overload          ; 0 = dim, 1 = overloaded (Battery collected)
    .importzp player_hp         ; remaining hit points (0 = dead)
    .importzp inv_timer         ; invincibility frames remaining

    ; -----------------------------------------------------------------------
    ; State values
    ; -----------------------------------------------------------------------
    STATE_IDLE   = 0
    STATE_RUN    = 1
    STATE_JUMP   = 2
    STATE_FALL   = 3
    STATE_DASH   = 4
    STATE_ATTACK = 5

    ; -----------------------------------------------------------------------
    ; Flag bits  (stored in Player::flags)
    ; -----------------------------------------------------------------------
    FLAG_GROUNDED  = %00000001  ; player is standing on a surface
    FLAG_FACING_L  = %00000010  ; player faces left (0 = right)
    FLAG_DASH_USED = %00000100  ; dash on cooldown until next landing

    ; -----------------------------------------------------------------------
    ; Subroutines
    ; -----------------------------------------------------------------------
    .import init    ; call once at level start
    .import tick    ; call once per game frame (before PPU::update)
    .import render  ; call once per game frame (after tick, before PPU::update)
    .import hurt    ; call when player is hit by enemy/projectile

.endscope ; Player

.endif ; Player_included
