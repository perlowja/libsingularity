using Gtk;
using Gdk;

namespace Singularity.Widgets {

    public class MediaPlayerCard : Box {
        private Stack cover_stack;
        private Picture cover_art_picture;
        private Gdk.Texture? _bg_texture = null;  // disegnata in snapshot(), non come widget
        private Image cover_art_icon;
        private Label title_label;
        private Label artist_label;
        private Button play_btn;
        private Button next_btn;
        private Button prev_btn;
        private Scale progress_scale;
        private Label time_current_label;
        private Label time_total_label;
        private DBusConnection? connection = null;
        private string? current_player_name = null;
        private uint _dbus_setup_source = 0;
        private uint _signal_sub_id = 0;
        private uint _player_props_sub_id = 0;
        private uint _poll_timer_id = 0;
        private bool _update_in_progress = false;
        private bool _update_again = false;
        private int64 track_length_us = 0;
        private int64 _last_seek_us = 0;
        private string track_id = "";
        private string? last_art_url = null;
        private string accent_hex = "#3584e4";

        /**
         * When true, the card stays visible even with no active MPRIS player
         * (showing a "Music idle" placeholder). When false (default), the
         * card hides itself when nothing is playing - useful in the sidebar
         * where empty space should disappear.
         */
        private bool _always_visible = false;
        public bool always_visible {
            get { return _always_visible; }
            set {
                _always_visible = value;
                if (value) this.visible = true;
                else if (current_player_name == null) this.visible = false;
                else request_state_update();
            }
        }

        public MediaPlayerCard() {
            Object(orientation: Orientation.VERTICAL, spacing: 0);
            update_accent_color();
            Singularity.Style.StyleManager.get_default().notify["accent-hex"].connect(() => {
                update_accent_color();
                queue_draw();
            });
            add_css_class("media-player-card");
            overflow = Overflow.HIDDEN;
            // Hidden by default; shown only when a player is active.
            visible = false;

            // Cover art: Stack con Picture (art reale) e Image (fallback)
            cover_stack = new Stack();
            cover_stack.set_size_request(64, 64);
            cover_stack.valign = Align.CENTER;
            cover_stack.halign = Align.CENTER;
            cover_stack.add_css_class("album-art");
            cover_stack.overflow = Overflow.HIDDEN;
            cover_art_icon = new Image.from_icon_name("audio-x-generic-symbolic");
            cover_art_icon.pixel_size = 28;
            cover_art_icon.valign = Align.CENTER;
            cover_art_icon.halign = Align.CENTER;
            cover_stack.add_named(cover_art_icon, "icon");
            cover_art_picture = new Picture();
            cover_art_picture.content_fit = ContentFit.COVER;
            cover_art_picture.can_shrink = true;
            cover_stack.add_named(cover_art_picture, "art");
            cover_stack.visible_child_name = "icon";

            // Info
            var info_box = new Box(Orientation.VERTICAL, 2);
            info_box.valign = Align.CENTER;
            info_box.hexpand = true;
            title_label = new Label(_("No Media"));
            title_label.add_css_class("title");
            title_label.halign = Align.START;
            title_label.xalign = 0.0f;
            title_label.hexpand = true;
            title_label.ellipsize = Pango.EllipsizeMode.END;
            artist_label = new Label("");
            artist_label.add_css_class("artist");
            artist_label.add_css_class("dim-label");
            artist_label.halign = Align.START;
            artist_label.xalign = 0.0f;
            artist_label.hexpand = true;
            artist_label.ellipsize = Pango.EllipsizeMode.END;
            info_box.append(title_label);
            info_box.append(artist_label);

            // Controls
            var controls_box = new Box(Orientation.HORIZONTAL, 4);
            controls_box.valign = Align.CENTER;
            prev_btn = new Button();
            var prev_img = new Image.from_icon_name("media-skip-backward-symbolic");
            prev_img.pixel_size = 14;
            prev_btn.child = prev_img;
            prev_btn.add_css_class("media-small-btn");
            prev_btn.add_css_class("flat");
            prev_btn.clicked.connect(on_prev_clicked);
            play_btn = new Button();
            var play_img = new Image.from_icon_name("media-playback-start-symbolic");
            play_img.pixel_size = 18;
            play_btn.child = play_img;
            play_btn.add_css_class("circular-button");
            play_btn.add_css_class("accent-button");
            play_btn.clicked.connect(on_play_clicked);
            next_btn = new Button();
            var next_img = new Image.from_icon_name("media-skip-forward-symbolic");
            next_img.pixel_size = 14;
            next_btn.child = next_img;
            next_btn.add_css_class("media-small-btn");
            next_btn.add_css_class("flat");
            next_btn.clicked.connect(on_next_clicked);
            controls_box.append(prev_btn);
            controls_box.append(play_btn);
            controls_box.append(next_btn);

            var info_controls_row = new Box(Orientation.HORIZONTAL, 8);
            info_controls_row.append(info_box);
            info_controls_row.append(controls_box);

            var right_box = new Box(Orientation.VERTICAL, 6);
            right_box.hexpand = true;
            right_box.valign = Align.CENTER;
            right_box.append(info_controls_row);

            // Progress
            var progress_box = new Box(Orientation.HORIZONTAL, 6);
            time_current_label = new Label("0:00");
            time_current_label.add_css_class("dim-label");
            time_current_label.add_css_class("caption");
            time_current_label.width_chars = 4;
            time_current_label.xalign = 1.0f;
            progress_scale = new Scale.with_range(Orientation.HORIZONTAL, 0.0, 1.0, 0.001);
            progress_scale.draw_value = false;
            progress_scale.hexpand = true;
            progress_scale.valign = Align.CENTER;
            progress_scale.sensitive = false;
            progress_scale.change_value.connect((scroll, value) => {
                if (current_player_name != null && track_length_us > 0) {
                    _last_seek_us = GLib.get_monotonic_time();
                    int64 pos_us = (int64)(value.clamp(0.0, 1.0) * track_length_us);
                    seek_to.begin(pos_us);
                }
                return false;
            });
            time_total_label = new Label("0:00");
            time_total_label.add_css_class("dim-label");
            time_total_label.add_css_class("caption");
            time_total_label.width_chars = 4;
            time_total_label.xalign = 0.0f;
            progress_box.append(time_current_label);
            progress_box.append(progress_scale);
            progress_box.append(time_total_label);
            right_box.append(progress_box);

            // contenuto diretto nel Box - niente Overlay, niente bg widget
            var main_row = new Box(Orientation.HORIZONTAL, 12);
            main_row.hexpand = true;
            main_row.vexpand = true;
            main_row.valign = Align.CENTER;
            main_row.margin_top    = 12;
            main_row.margin_bottom = 12;
            main_row.margin_start  = 12;
            main_row.margin_end    = 12;
            main_row.append(cover_stack);
            main_row.append(right_box);
            append(main_row);

            _dbus_setup_source = Idle.add(() => {
                _dbus_setup_source = 0;
                setup_dbus.begin();
                return Source.REMOVE;
            });
        }

        // Disegna bg_texture con clip arrotondato + dim accent, poi i figli sopra
        protected override void snapshot(Gtk.Snapshot snap) {
            if (_bg_texture != null) {
                float w = (float) get_width ();
                float h = (float) get_height ();
                var rect = Graphene.Rect ();
                rect.init (0, 0, w, h);
                var rrect = Gsk.RoundedRect ();
                rrect.init_from_rect (rect, 12);
                snap.push_rounded_clip (rrect);

                // object-fit: cover
                float tex_w = (float) _bg_texture.width;
                float tex_h = (float) _bg_texture.height;
                float scale = float.max (w / tex_w, h / tex_h);
                float draw_w = tex_w * scale;
                float draw_h = tex_h * scale;
                float dx = (w - draw_w) / 2.0f;
                float dy = (h - draw_h) / 2.0f;
                var draw_rect = Graphene.Rect ();
                draw_rect.init (dx, dy, draw_w, draw_h);

                // immagine più trasparente
                snap.push_opacity (0.18);
                snap.append_texture (_bg_texture, draw_rect);
                snap.pop ();

                // velo accent color semitrasparente
                // velo accent leggero
                var tint = Gdk.RGBA ();
                tint.parse (accent_hex);
                tint.alpha = 0.22f;
                snap.append_color (tint, rect);

                // layer scuro per desaturare e scurire
                var dark = Gdk.RGBA ();
                dark.red = 0.0f; dark.green = 0.0f; dark.blue = 0.0f;
                dark.alpha = 0.45f;
                snap.append_color (dark, rect);

                snap.pop (); // rounded clip
            }
            base.snapshot (snap);
        }

        private async void setup_dbus() {
            try {
                connection = yield Bus.get(BusType.SESSION);

                _signal_sub_id = connection.signal_subscribe(
                    "org.freedesktop.DBus",
                    "org.freedesktop.DBus",
                    "NameOwnerChanged",
                    "/org/freedesktop/DBus",
                    null,
                    DBusSignalFlags.NONE,
                    (conn, sender, obj_path, iface, sig, pars) => {
                        string? name      = (string?) pars.get_child_value(0);
                        string? old_owner = (string?) pars.get_child_value(1);
                        string? new_owner = (string?) pars.get_child_value(2);
                        if (name == null || !name.has_prefix("org.mpris.MediaPlayer2.")) return;
                        if (new_owner != null && new_owner != "") {
                            connect_to_player(name);
                        } else if ((new_owner == null || new_owner == "") && name == current_player_name) {
                            disconnect_player();
                            current_player_name = null;
                            update_ui_idle();
                            find_player.begin();
                        }
                    }
                );

                find_player.begin();
                _schedule_next_poll(5);
            } catch (Error e) {
                warning("Failed to setup DBus for Media Player: %s", e.message);
            }
        }

        private void _schedule_next_poll(uint interval_seconds) {
            if (_poll_timer_id != 0) {
                Source.remove(_poll_timer_id);
            }
            _poll_timer_id = Timeout.add_seconds(interval_seconds, () => {
                _poll_timer_id = 0;
                if (current_player_name != null) {
                    request_state_update();
                } else {
                    find_player.begin();
                }
                _schedule_next_poll(current_player_name != null ? 1 : 5);
                return Source.REMOVE;
            });
        }

        private async void find_player() {
            var bus = connection;
            if (bus == null) return;
            try {
                var result = yield bus.call(
                    "org.freedesktop.DBus", "/org/freedesktop/DBus",
                    "org.freedesktop.DBus", "ListNames", null,
                    new VariantType("(as)"), DBusCallFlags.NONE, 1000, null);
                VariantIter iter;
                result.get("(as)", out iter);
                string? best_name = null;
                string? name;
                while (iter.next("s", out name)) {
                    if (name == null) continue;
                    if (!name.has_prefix("org.mpris.MediaPlayer2.")) continue;
                    if (best_name == null) best_name = name;
                    if (yield player_is_playing(name)) {
                        best_name = name;
                        break;
                    }
                }
                if (best_name != null) connect_to_player(best_name);
            } catch (Error e) { }
        }

        private async bool player_is_playing(string name) {
            var bus = connection;
            if (bus == null) return false;
            try {
                var result = yield bus.call(name, "/org/mpris/MediaPlayer2",
                    "org.freedesktop.DBus.Properties", "Get",
                    new Variant("(ss)", "org.mpris.MediaPlayer2.Player",
                        "PlaybackStatus"),
                    new VariantType("(v)"), DBusCallFlags.NONE, 500, null);
                return result.get_child_value(0).get_variant().get_string()
                    == "Playing";
            } catch (Error e) {
                return false;
            }
        }

        private void update_accent_color() {
            string resolved = Singularity.Style.StyleManager.get_default().accent_hex;
            accent_hex = (resolved != "") ? resolved : "#3584e4";
        }

        private void connect_to_player(string name) {
            var bus = connection;
            if (bus == null || name == current_player_name) return;
            disconnect_player();
            current_player_name = name;
            _player_props_sub_id = bus.signal_subscribe(name,
                "org.freedesktop.DBus.Properties", "PropertiesChanged",
                "/org/mpris/MediaPlayer2", "org.mpris.MediaPlayer2.Player",
                DBusSignalFlags.NONE,
                (conn, sender, path, iface, sig, parameters) => {
                    request_state_update();
                });
            request_state_update();
        }

        private void disconnect_player() {
            if (_player_props_sub_id != 0 && connection != null) {
                connection.signal_unsubscribe(_player_props_sub_id);
                _player_props_sub_id = 0;
            }
        }

        private void request_state_update() {
            if (_update_in_progress) {
                _update_again = true;
                return;
            }
            update_state.begin();
        }

        private async void update_state() {
            var bus = connection;
            var name = current_player_name;
            if (bus == null || name == null) return;
            _update_in_progress = true;
            try {
                var all = yield bus.call(name, "/org/mpris/MediaPlayer2",
                    "org.freedesktop.DBus.Properties", "GetAll",
                    new Variant("(s)", "org.mpris.MediaPlayer2.Player"),
                    new VariantType("(a{sv})"), DBusCallFlags.NONE, 1000, null);
                if (name != current_player_name) return;
                var properties = all.get_child_value(0);
                var metadata_variant = properties.lookup_value("Metadata", null);
                var status_variant = properties.lookup_value("PlaybackStatus", null);
                int64 pos_us = 0;
                try {
                    var pos_result = yield bus.call(name,
                        "/org/mpris/MediaPlayer2",
                        "org.freedesktop.DBus.Properties", "Get",
                        new Variant("(ss)", "org.mpris.MediaPlayer2.Player", "Position"),
                        new VariantType("(v)"), DBusCallFlags.NONE, 500, null);
                    pos_us = pos_result.get_child_value(0).get_variant().get_int64();
                } catch (Error pe) {}
                if (name != current_player_name) return;
                string title = "Unknown Title";
                string artist = "Unknown Artist";
                string art_url = "";
                string status = "Stopped";
                if (status_variant != null) {
                    status = status_variant.get_string();
                }
                if (metadata_variant != null) {
                    var title_variant = metadata_variant.lookup_value("xesam:title", null);
                    if (title_variant != null) title = title_variant.get_string();
                    var artist_variant = metadata_variant.lookup_value("xesam:artist", null);
                    if (artist_variant != null) {
                        if (artist_variant.is_of_type(new VariantType("as"))) {
                            var artists = artist_variant.get_strv();
                            if (artists.length > 0) artist = artists[0];
                        } else if (artist_variant.is_of_type(VariantType.STRING)) {
                            artist = artist_variant.get_string();
                        }
                    }
                    var art_variant = metadata_variant.lookup_value("mpris:artUrl", null);
                    if (art_variant != null) art_url = art_variant.get_string();
                    var tid_variant = metadata_variant.lookup_value("mpris:trackid", null);
                    track_id = (tid_variant != null) ? tid_variant.get_string() : "";
                    var length_variant = metadata_variant.lookup_value("mpris:length", null);
                    if (length_variant != null) {
                        // MPRIS spec says int64 ("x"), but some players send uint64 ("t")
                        var ltype = length_variant.get_type_string();
                        if (ltype == "x") {
                            track_length_us = length_variant.get_int64();
                        } else if (ltype == "t") {
                            track_length_us = (int64)length_variant.get_uint64();
                        } else if (ltype == "i") {
                            track_length_us = (int64)length_variant.get_int32();
                        } else if (ltype == "u") {
                            track_length_us = (int64)length_variant.get_uint32();
                        } else {
                            track_length_us = 0;
                        }
                    } else {
                        track_length_us = 0;
                    }
                }
                title_label.label = title;
                artist_label.label = artist;
                if (status == "Playing") {
                    play_btn.icon_name = "media-playback-pause-symbolic";
                } else {
                    play_btn.icon_name = "media-playback-start-symbolic";
                }
                var previous_variant = properties.lookup_value("CanGoPrevious", null);
                var next_variant = properties.lookup_value("CanGoNext", null);
                prev_btn.sensitive = previous_variant != null
                    && previous_variant.get_boolean();
                next_btn.sensitive = next_variant != null
                    && next_variant.get_boolean();
                // Show widget only when a track is actively playing or paused
                // (unless `always_visible` is on - used by the overview widget,
                // which renders its own slot regardless of media state).
                this.visible = always_visible || (status == "Playing" || status == "Paused");
                if (art_url != "") {
                    load_cover(art_url);
                }
                // Update progress bar
                if (track_length_us > 0) {
                    if (GLib.get_monotonic_time() - _last_seek_us > 1500000) {
                        double fraction = (double)pos_us / (double)track_length_us;
                        progress_scale.set_value(fraction.clamp(0.0, 1.0));
                        time_current_label.label = format_time(pos_us);
                    }
                    time_total_label.label = format_time(track_length_us);
                    progress_scale.sensitive = true;
                } else {
                    progress_scale.set_value(0.0);
                    time_current_label.label = "0:00";
                    time_total_label.label = "0:00";
                    progress_scale.sensitive = false;
                }
            } catch (Error e) {
                update_ui_idle();
            } finally {
                _update_in_progress = false;
                if (_update_again) {
                    _update_again = false;
                    request_state_update();
                }
            }
        }

        private void update_ui_idle() {
            title_label.label = _("No Media");
            artist_label.label = "";
            last_art_url = null;
            cover_stack.visible_child_name = "icon";
            play_btn.icon_name = "media-playback-start-symbolic";
            progress_scale.set_value(0.0);
            progress_scale.sensitive = false;
            time_current_label.label = "0:00";
            time_total_label.label = "0:00";
            track_length_us = 0;
            this.visible = always_visible;
        }

        private void load_cover(string url) {
            if (url == last_art_url) return;
            last_art_url = url;
            if (url.has_prefix("file://")) {
                var path = Uri.unescape_string(url.substring(7));
                try {
                    // The cover Picture sizes to its texture, and the card slot
                    // is 64px, so load it at the display size (a bigger texture
                    // made the whole card huge). The blurred background below is
                    // a drawn paintable, not a widget, so it stays higher-res.
                    var pixbuf = new Gdk.Pixbuf.from_file_at_scale(path, 64, 64, true);
                    var texture = Gdk.Texture.for_pixbuf(pixbuf);
                    cover_art_picture.set_paintable(texture);
                    cover_stack.visible_child_name = "art";
                    try {
                        var bg_pixbuf = new Gdk.Pixbuf.from_file_at_scale(path, 384, 384, true);
                        _bg_texture = Gdk.Texture.for_pixbuf(bg_pixbuf);
                    } catch { _bg_texture = texture; }
                    queue_draw();
                } catch (Error e) {
                    cover_stack.visible_child_name = "icon";
                    _bg_texture = null;
                    queue_draw();
                }
            } else if (url.has_prefix("http://") || url.has_prefix("https://")) {
                load_remote_cover.begin(url);
            } else {
                cover_stack.visible_child_name = "icon";
                _bg_texture = null;
                queue_draw();
            }
        }

        private async void load_remote_cover(string url) {
            try {
                var session = new Soup.Session();
                var msg = new Soup.Message("GET", url);
                var input_stream = yield session.send_async(msg, Priority.DEFAULT, null);
                if (msg.status_code == 200) {
                    var pixbuf = yield new Gdk.Pixbuf.from_stream_async(input_stream, null);
                    if (pixbuf.width > 384 || pixbuf.height > 384) {
                        double bg_scale = double.min(384.0 / pixbuf.width, 384.0 / pixbuf.height);
                        int bg_w = int.max(1, (int)(pixbuf.width * bg_scale));
                        int bg_h = int.max(1, (int)(pixbuf.height * bg_scale));
                        _bg_texture = Gdk.Texture.for_pixbuf(pixbuf.scale_simple(bg_w, bg_h, Gdk.InterpType.BILINEAR));
                    } else {
                        _bg_texture = Gdk.Texture.for_pixbuf(pixbuf);
                    }
                    queue_draw();
                    if (pixbuf.width > 64 || pixbuf.height > 64) {
                        double scale = double.min(64.0 / pixbuf.width, 64.0 / pixbuf.height);
                        int new_w = (int)(pixbuf.width * scale);
                        int new_h = (int)(pixbuf.height * scale);
                        pixbuf = pixbuf.scale_simple(new_w, new_h, Gdk.InterpType.BILINEAR);
                    }
                    cover_art_picture.set_paintable(Gdk.Texture.for_pixbuf(pixbuf));
                    cover_stack.visible_child_name = "art";
                } else {
                    cover_stack.visible_child_name = "icon";
                    _bg_texture = null;
                    queue_draw();
                }
            } catch (Error e) {
                cover_stack.visible_child_name = "icon";
                _bg_texture = null;
                queue_draw();
            }
        }

        private async void seek_to(int64 pos_us) {
            var bus = connection;
            var name = current_player_name;
            if (bus == null || name == null) return;
            if (track_id != "" && track_id != "/org/mpris/MediaPlayer2/TrackList/NoTrack") {
                try {
                    yield bus.call(name, "/org/mpris/MediaPlayer2",
                        "org.mpris.MediaPlayer2.Player", "SetPosition",
                        new Variant("(ox)", track_id, pos_us),
                        null, DBusCallFlags.NONE, 1000, null);
                    return;
                } catch (Error e) {}
            }
            try {
                yield bus.call(name, "/org/mpris/MediaPlayer2",
                    "org.mpris.MediaPlayer2.Player", "Seek",
                    new Variant("(x)", pos_us - (int64)((progress_scale.get_value()) * track_length_us)),
                    null, DBusCallFlags.NONE, 1000, null);
            } catch (Error e) {}
        }

        private static string format_time(int64 microseconds) {
            if (microseconds < 0) microseconds = 0;
            int64 secs = microseconds / 1000000;
            return "%lld:%02lld".printf(secs / 60, secs % 60);
        }

        private void on_play_clicked() {
            player_action.begin("PlayPause");
        }

        private void on_next_clicked() {
            player_action.begin("Next");
        }

        private void on_prev_clicked() {
            player_action.begin("Previous");
        }

        private async void player_action(string method) {
            var bus = connection;
            var name = current_player_name;
            if (bus == null || name == null) return;
            try {
                yield bus.call(name, "/org/mpris/MediaPlayer2",
                    "org.mpris.MediaPlayer2.Player", method, null, null,
                    DBusCallFlags.NONE, 1000, null);
                request_state_update();
            } catch (Error e) { }
        }

        protected override void dispose() {
            if (_dbus_setup_source != 0) {
                Source.remove(_dbus_setup_source);
                _dbus_setup_source = 0;
            }
            if (_poll_timer_id != 0) {
                Source.remove(_poll_timer_id);
                _poll_timer_id = 0;
            }
            if (_signal_sub_id != 0 && connection != null) {
                connection.signal_unsubscribe(_signal_sub_id);
                _signal_sub_id = 0;
            }
            disconnect_player();
            base.dispose();
        }
    }
}
