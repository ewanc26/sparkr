; NES Gamepad module
; Useful constants and subroutines

.ifndef Joy_included
Joy_included = 1
.scope Joy
    .import PAD0_ADDR
    .import PAD1_ADDR

    ; button state masks — bit layout matches SMB (A=%10000000 ... Right=%00000001)
    BUTTON_A      = %10000000
    BUTTON_B      = %01000000
    BUTTON_SELECT = %00100000
    BUTTON_START  = %00010000
    BUTTON_UP     = %00001000
    BUTTON_DOWN   = %00000100
    BUTTON_LEFT   = %00000010
    BUTTON_RIGHT  = %00000001

    .importzp pad_0
    .importzp new_buttons_0
    .import   poll
    .import   store_new_buttons
.endscope ; Joy
.endif ; .ifndef Joy_included
