# Native libadwaita integration

libsingularity now requires libadwaita 1.2 or newer. Its shared style initialization
initializes Adw before application and shell widgets are constructed. Native Adw
widget styles coexist with Singularity's higher-priority brand CSS. Dark and light
mode changes are forwarded to Adw.StyleManager as well as the existing CSS loader.

The wallpaper browser and sensors popover in singularity-shell use native Adw
widgets directly. The existing Singularity.Widgets preference classes remain a
legacy API; they are not aliases for libadwaita types.

A transparent replacement of that API would break existing inheritance:
Singularity.Widgets.ActionRow derives from PreferencesRow, while EntryRow and
ExpanderRow derive from ActionRow. Adw.EntryRow and Adw.ExpanderRow instead derive
from Adw.PreferencesRow. Shell callers depend on the old relationships for typed
plugin rows and settings search. The legacy confirmation implementation also
reparents row children, and password/email subclasses depend on an exposed
Gtk.Entry. A complete migration therefore needs explicit caller and interaction
changes, rather than merely substituting superclass names.

The scoped conversion avoids those unrelated API changes while giving the
wallpaper browser and sensors genuine libadwaita widgets. A future shared API
migration should address those dependencies and test all consuming applications.
