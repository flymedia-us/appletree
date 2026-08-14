# Paths are injected by scripts/package-dmg.sh via `dmgbuild -D`.
app = defines["app"]
background = defines["background"]
icon = defines["icon"]

files = [app]
symlinks = {"Applications": "/Applications"}
hide_extensions = ["AppleTree.app"]

# Window points; must stay aligned with packaging/dmg/render-background.swift.
icon_locations = {
    "AppleTree.app": (168, 190),
    "Applications": (492, 190),
}

format = "UDZO"
filesystem = "HFS+"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
include_icon_view_settings = True
default_view = "icon-view"

# ((x, y), (width, height)) — y is from the bottom of the screen.
window_rect = ((200, 120), (660, 400))
icon_size = 128
text_size = 12
label_pos = "bottom"
