; inc/enemies.inc — Public interface for the Sparkr enemy system module.

.ifndef Enemies_included
Enemies_included = 1

.scope Enemy

    ; -----------------------------------------------------------------------
    ; Enemy type constants
    ; -----------------------------------------------------------------------
    ENEMY_TYPE_NONE    = 0
    ENEMY_TYPE_ZAPPER  = 1
    ENEMY_TYPE_FLOATER = 2
    ENEMY_TYPE_SHOCKER = 3

    MAX_ENEMIES = 4

    ; -----------------------------------------------------------------------
    ; RAM arrays (exported for read-only access by other modules)
    ; -----------------------------------------------------------------------
    .import enemy_x, enemy_y, enemy_vx
    .import enemy_type, enemy_timer, enemy_hp
    .import proj_x, proj_y, proj_vx, proj_active

    ; -----------------------------------------------------------------------
    ; Subroutines
    ; -----------------------------------------------------------------------
    .import init_all    ; zero all slots and projectile
    ; spawn: X=slot, A=type, local_0=x, local_1=y
    .import spawn
    .import tick_all    ; AI + physics + collision (call once per frame)
    .import render_all  ; write OAM slots 4-8 (call once per frame)
    .import all_dead    ; returns A=1 if all clear, A=0 otherwise

.endscope ; Enemy

.endif ; Enemies_included
