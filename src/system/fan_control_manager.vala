using GLib;

namespace Singularity {

    [DBus (name = "dev.sinty.FanControl1")]
    public interface FanControlProxy : Object {
        public abstract async HashTable<string, Variant>[] get_channels() throws Error;
        public abstract async void set_curve(string id, int[] temps, int[] percents) throws Error;
        public abstract async void reset_firmware(string id) throws Error;
        public signal void channels_changed();
    }

    public class FanControlChannel : Object {
        public string id { get; private set; default = ""; }
        public string hwmon { get; private set; default = ""; }
        public int pwm_channel { get; private set; default = 0; }
        public string label { get; private set; default = ""; }
        public string method { get; private set; default = ""; }
        public string active { get; private set; default = "firmware"; }
        public string reason { get; private set; default = ""; }
        public int crit_millidegrees { get; private set; default = 100000; }
        public int min_percent { get; private set; default = 20; }
        public int max_points { get; private set; default = 6; }
        public int[] temps = {};
        public int[] percents = {};

        public bool tunable {
            get { return method != ""; }
        }

        public FanControlChannel.from_dict(HashTable<string, Variant> dict) {
            id = string_of(dict, "id");
            hwmon = string_of(dict, "hwmon");
            label = string_of(dict, "label");
            method = string_of(dict, "method");
            active = string_of(dict, "active");
            reason = string_of(dict, "reason");
            pwm_channel = int_of(dict, "pwm", 0);
            crit_millidegrees = int_of(dict, "crit", 100000);
            min_percent = int_of(dict, "min_percent", 20);
            max_points = int_of(dict, "max_points", 6);
            temps = ints_of(dict, "temps");
            percents = ints_of(dict, "percents");
        }

        private static string string_of(HashTable<string, Variant> dict, string key) {
            Variant? value = dict.lookup(key);
            return value != null && value.is_of_type(VariantType.STRING) ? value.get_string() : "";
        }

        private static int int_of(HashTable<string, Variant> dict, string key, int fallback) {
            Variant? value = dict.lookup(key);
            return value != null && value.is_of_type(VariantType.INT32) ? value.get_int32() : fallback;
        }

        private static int[] ints_of(HashTable<string, Variant> dict, string key) {
            int[] values = {};
            Variant? value = dict.lookup(key);
            if (value == null || !value.is_of_type(new VariantType("ai"))) return values;
            for (size_t i = 0; i < value.n_children(); i++) {
                values += value.get_child_value(i).get_int32();
            }
            return values;
        }
    }

    public class FanControlManager : Object {
        private static FanControlManager? _instance = null;
        private FanControlProxy? proxy = null;
        private FanControlChannel[] _channels = {};

        public bool available { get; private set; default = false; }
        public signal void changed();

        public static FanControlManager get_default() {
            if (_instance == null) _instance = new FanControlManager();
            return _instance;
        }

        public FanControlChannel[] channels() {
            return _channels;
        }

        public FanControlChannel? find(string hwmon, int pwm_channel) {
            foreach (var channel in _channels) {
                if (channel.hwmon == hwmon && channel.pwm_channel == pwm_channel) return channel;
            }
            return null;
        }

        public async void refresh() {
            try {
                if (proxy == null) {
                    proxy = yield Bus.get_proxy<FanControlProxy>(
                        BusType.SYSTEM, "dev.sinty.FanControl", "/dev/sinty/FanControl");
                    proxy.channels_changed.connect(() => refresh.begin());
                }
                var dicts = yield proxy.get_channels();
                FanControlChannel[] found = {};
                foreach (var dict in dicts) {
                    found += new FanControlChannel.from_dict(dict);
                }
                _channels = found;
                available = true;
            } catch (Error e) {
                _channels = {};
                available = false;
            }
            changed();
        }

        public async void set_curve(string id, int[] temps, int[] percents) throws Error {
            if (proxy == null) throw new IOError.NOT_CONNECTED("The fan control service is not running");
            try {
                yield proxy.set_curve(id, temps, percents);
            } catch (Error e) {
                DBusError.strip_remote_error(e);
                throw e;
            }
            yield refresh();
        }

        public async void reset_firmware(string id) throws Error {
            if (proxy == null) throw new IOError.NOT_CONNECTED("The fan control service is not running");
            try {
                yield proxy.reset_firmware(id);
            } catch (Error e) {
                DBusError.strip_remote_error(e);
                throw e;
            }
            yield refresh();
        }
    }
}
