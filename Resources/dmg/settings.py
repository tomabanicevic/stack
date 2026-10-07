# dmgbuild settings — https://dmgbuild.readthedocs.io
import os.path

application = defines.get("app", "build/Stack.app")  # noqa: F821 (injected by dmgbuild)
appname = os.path.basename(application)

format = "UDZO"
filesystem = "HFS+"
files = [application]
symlinks = {"Applications": "/Applications"}
icon = os.path.join(application, "Contents", "Resources", "AppIcon.icns")
background = defines.get("background", "builtin-arrow")  # noqa: F821

show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
sidebar_width = 0
window_rect = ((200, 140), (640, 428))
default_view = "icon-view"
show_icon_preview = False
arrange_by = None
icon_size = 112
text_size = 13
icon_locations = {appname: (170, 190), "Applications": (470, 190)}
