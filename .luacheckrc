-- Mirror KOReader's luacheck conventions so the plugin lints cleanly
-- against the same rules as the host application.
unused_args = false
std = "luajit"
-- ignore implicit self
self = false

read_globals = {
    "_ENV",
}

ignore = {
    "211/__*", -- Unused local variable
    "231/__",  -- Local variable is set but never accessed
    "631",     -- Line is too long
    "dummy",
}
