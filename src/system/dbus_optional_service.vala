using GLib;

namespace Singularity {

    /**
     * Small helpers for wrapping an OPTIONAL external D-Bus service --
     * NetworkManager, BlueZ, UPower/PowerProfiles, GNOME Online Accounts, and
     * anything else a widget may or may not have on a given system.
     *
     * The failure mode this exists to prevent: a wrapper constructs a proxy
     * or calls an async init method against a service that is not running.
     * If that name happens to be dbus-activatable, the bus daemon may try to
     * start it on demand before answering -- and if the backing unit is
     * masked, missing a dependency, or otherwise broken, that activation
     * attempt can take real time to fail. Nothing about "the call is async"
     * protects a caller that is, in effect, waiting for the async call to
     * resolve before it can show real content (a wifi list, a device list,
     * an active profile) -- the UI is left showing nothing useful for
     * however long the failure takes to surface.
     *
     * `has_owner()` and `deadline()` are meant to be composed by each
     * wrapper's own init function, matching this codebase's existing style
     * of one small try/catch per wrapper rather than a shared "connect to
     * an optional service" abstraction -- there are only a handful of these
     * and each already has its own graceful-degradation shape.
     */
    namespace DBusOptionalService {

        /**
         * True iff `bus_name` currently has an owner on `bus_type`. Answered
         * directly by the bus daemon itself (always present), so this never
         * triggers D-Bus service activation and always resolves in one
         * round trip -- regardless of whether the service being asked about
         * is running, merely activatable, or entirely absent.
         *
         * Useful as a cheap up-front signal, but NOT sufficient on its own
         * to decide a service is unavailable: a name that is activatable
         * but not yet owned is a normal, healthy state on systems that
         * start services on demand. Pair with `deadline()` around the real
         * connection attempt rather than skipping it on a false reading
         * here.
         */
        public async bool has_owner(BusType bus_type, string bus_name) {
            try {
                var conn = yield Bus.get(bus_type);
                var reply = yield conn.call(
                    "org.freedesktop.DBus", "/org/freedesktop/DBus",
                    "org.freedesktop.DBus", "NameHasOwner",
                    new Variant("(s)", bus_name), new VariantType("(b)"),
                    DBusCallFlags.NONE, 2000, null);
                bool owned;
                reply.get("(b)", out owned);
                return owned;
            } catch (Error e) {
                warning("DBusOptionalService.has_owner(%s): %s", bus_name, e.message);
                return false;
            }
        }

        /**
         * A Cancellable that fires after `timeout_seconds`. Pass it to the
         * async D-Bus call being bounded (proxy construction, an init
         * method, a method call) so a connection attempt that is
         * legitimately still activating a service resolves normally in the
         * common case (milliseconds), while one that is stuck -- a masked
         * unit, a daemon that never comes up -- is abandoned instead of
         * left to whatever timeout the bus/transport would otherwise use.
         *
         * On firing, the bounded call ends with IOError.CANCELLED; treat
         * that exactly like any other connection failure in the caller's
         * catch block (log, mark the service unavailable, degrade the UI).
         */
        public Cancellable deadline(uint timeout_seconds) {
            var cancellable = new Cancellable();
            Timeout.add_seconds(timeout_seconds, () => {
                cancellable.cancel();
                return Source.REMOVE;
            });
            return cancellable;
        }
    }
}
