# dmgbuild layout for the Postmere installer window.
# Positions must match script/dmg/background.swift.
import os.path

app = defines["app"]  # noqa: F821 (provided by dmgbuild)
background_dir = defines["background_dir"]  # noqa: F821
app_name = os.path.basename(app)

format = "ULFO"  # LZFSE: small, opens on macOS 10.11 and later
filesystem = "APFS"
files = [app]
symlinks = {"Applications": "/Applications"}
hide_extension = [app_name]

background = os.path.join(background_dir, "background.tiff")
window_rect = ((200, 120), (640, 420))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 128
text_size = 13
label_pos = "bottom"
icon_locations = {
    app_name: (170, 196),
    "Applications": (470, 196),
}
