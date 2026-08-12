using GLib;

namespace Singularity {

    public enum SensorKind {
        CPU,
        GPU,
        SYSTEM
    }

    /** One temperature sensor, as reported by the kernel. */
    public class SensorReading : Object {
        public string label { get; private set; }
        public int millidegrees { get; private set; }
        public SensorKind kind { get; private set; }

        public SensorReading(string label, int millidegrees, SensorKind kind) {
            this.label = label;
            this.millidegrees = millidegrees;
            this.kind = kind;
        }
    }

    /** One power rail, in milliwatts. */
    public class PowerReading : Object {
        public string label { get; private set; }
        public int milliwatts { get; private set; }

        public PowerReading(string label, int milliwatts) {
            this.label = label;
            this.milliwatts = milliwatts;
        }
    }

    /** One fan, as reported by hwmon. */
    public class FanReading : Object {
        public string label { get; private set; }
        public int rpm { get; private set; }

        public FanReading(string label, int rpm) {
            this.label = label;
            this.rpm = rpm;
        }
    }

    /**
     * Reads temperatures, fan speeds and CPU clocks from sysfs.
     *
     * SOURCES. /sys/class/hwmon is primary: it is the generic kernel interface
     * and covers x86 (coretemp, k10temp, zenpower) plus most GPUs (amdgpu,
     * nouveau, i915). /sys/class/thermal is the fallback, because a number of
     * ARM SoCs expose temperatures only there.
     *
     * CLASSIFICATION IS AN ALLOW-LIST, AND THAT IS THE WHOLE POINT.
     * An earlier version treated any unrecognised sensor as a CPU sensor. That
     * is wrong on ordinary hardware, and measurably so -- checked against four
     * machines, every one of them reported something that was not the CPU:
     *
     *   Ryzen 8700G desktop   picked "enp1s0 PHY" 68 C   (a NIC; CPU was 59 C)
     *   Threadripper          picked "enp1s0 PHY" 80 C   (a NIC; CPU was 67 C)
     *   Comet Lake laptop     picked "pch_cometlake" 43 C (chipset; CPU 36 C)
     *   Dell workstation      picked "dell_smm" 85 C     (SMM probe; CPU 47 C)
     *
     * An unknown sensor is therefore SYSTEM, never CPU. `cpu_millidegrees` is
     * -1 unless a sensor was positively identified as a CPU, so a caller can
     * tell "no CPU sensor here" from "the CPU is cold" instead of confidently
     * displaying a network chip as the processor temperature.
     *
     * SoCs whose zone names no generic list can know (CIX Sky1 uses TZB0/TZB1
     * for its big cluster and TZGT for graphics) are handled by cpu_hint and
     * gpu_hint, which a distribution can set without patching this file.
     *
     * NVIDIA. Their driver publishes NO hwmon node -- verified on both the
     * proprietary build (595.58) and the open kernel module (595.71); neither
     * creates one under /sys/class/hwmon or the DRM device. So NVIDIA GPUs are
     * queried through nvidia-smi instead, ASYNCHRONOUSLY and only when the
     * binary is present. Measured cost is 14-16 ms per query on an RTX 4500,
     * i.e. under 1% duty cycle at the default 2 s interval, and the call never
     * blocks the caller's thread. libnvidia-ml is also present on such systems,
     * so this could move to NVML later without a fork; nvidia-smi is chosen
     * first because it needs no new link-time dependency.
     *
     * POWER. Most boards expose no power rail at all (no power*_input,
     * curr*_input or energy*_uj), so no wattage is invented for them and
     * gpu_power_milliwatts stays -1. Where the hardware really does report it
     * -- NVIDIA via nvidia-smi -- it is passed through as measured.
     */
    public class SensorMonitor : Object {
        // Public because start() uses it as a default argument, and Vala requires
        // a default value to be at least as accessible as the method.
        public const int DEFAULT_INTERVAL_SEC = 2;

        private const string HWMON_DIR = "/sys/class/hwmon";
        private const string THERMAL_DIR = "/sys/class/thermal";
        private const string CPUFREQ_DIR = "/sys/devices/system/cpu/cpufreq";

        // Kernel driver names, not product names.
        private const string[] CPU_CHIPS = {
            "coretemp", "k10temp", "zenpower", "x86_pkg_temp",
            "cpu_thermal", "cpu-thermal", "soc_thermal", "soc-thermal",
            // Tegra/Thor-class boards name their zones this way.
            "cpu-therm", "tj-thermal",
            // Bare "cpu" catches the per-core Qualcomm naming (cpu0_0_thermal,
            // cpu1_2_thermal, ...) and anything else that spells it out; a
            // sensor with "cpu" in its name is a CPU sensor in practice.
            // "cluster" is the CPU cluster zone on those same SoCs.
            "cpu", "cluster",
            "armada_thermal", "imx_thermal", "sun4i-ts", "scpi-sensors"
        };
        // hwmon label text that identifies a CPU package or core.
        private const string[] CPU_LABELS = {
            "package id", "tctl", "tdie", "tccd", "core "
        };
        private const string[] GPU_CHIPS = {
            "amdgpu", "radeon", "nouveau", "i915", "xe",
            "panfrost", "panthor", "mali", "lima", "v3d", "vc4",
            // Tegra/Thor expose the integrated GPU as a thermal zone.
            "gpu-thermal", "gpu-therm",
            // Bare "gpu" also catches Qualcomm's GPU subsystem zones
            // (gpuss_0_thermal .. gpuss_7_thermal, Adreno). Checked before the
            // CPU list, so "gpuss" cannot be mistaken for a CPU sensor.
            "gpu"
        };

        private uint _timer_id = 0;
        private int _interval_sec = DEFAULT_INTERVAL_SEC;
        private SensorReading[] _readings = {};
        // Sysfs-derived readings only, without the NVIDIA set merged in.
        private SensorReading[] _base_readings = {};
        private int[] _clocks_khz = {};
        private FanReading[] _fans = {};
        private PowerReading[] _power = {};
        private SensorReading[] _nvidia_readings = {};
        private bool _nvidia_present = false;
        private bool _nvidia_checked = false;
        private bool _nvidia_in_flight = false;

        /** Hottest sensor positively identified as a CPU, or -1 if none. */
        public int cpu_millidegrees { get; private set; default = -1; }
        /** Hottest sensor identified as a GPU, or -1 if none. */
        public int gpu_millidegrees { get; private set; default = -1; }
        /** Hottest sensor that is neither, or -1. Use when there is no CPU. */
        public int system_millidegrees { get; private set; default = -1; }
        /** Highest current CPU clock in kHz, or -1 when cpufreq is absent. */
        public int cpu_khz { get; private set; default = -1; }
        /** False when the machine exposes nothing readable. */
        public bool available { get; private set; default = false; }
        /** GPU power draw where the hardware reports it, else -1. */
        public int gpu_power_milliwatts { get; private set; default = -1; }

        /**
         * Substring identifying the CPU/GPU sensor on hardware the allow-list
         * cannot know. Empty by default: a distribution sets these, and no
         * single vendor's naming is baked in here.
         */
        public string cpu_hint { get; set; default = ""; }
        public string gpu_hint { get; set; default = ""; }

        public signal void updated();

        public SensorMonitor() {}

        public void start(int interval_sec = DEFAULT_INTERVAL_SEC) {
            if (_timer_id != 0) return;
            _interval_sec = interval_sec > 0 ? interval_sec : DEFAULT_INTERVAL_SEC;
            refresh();
            _timer_id = Timeout.add_seconds(_interval_sec, () => {
                refresh();
                return Source.CONTINUE;
            });
        }

        public void stop() {
            if (_timer_id != 0) {
                Source.remove(_timer_id);
                _timer_id = 0;
            }
        }

        public override void dispose() {
            stop();
            base.dispose();
        }

        /** Every sensor read on the last refresh, in discovery order. */
        public SensorReading[] readings() {
            return _readings;
        }

        /** Current CPU clocks in kHz, highest first. */
        public int[] clocks_khz() {
            return _clocks_khz;
        }

        /**
         * Fans that are actually turning.
         *
         * Zero-RPM entries are omitted: a board commonly exposes more fan
         * headers than it has fans, and those read 0 forever. MEASURED on an
         * IGX Thor dev kit -- f75308 presents four headers of which two are
         * populated (1342 and 1046 RPM) and two read 0. Listing the empty ones
         * would imply two dead fans. A genuinely stopped fan is therefore also
         * hidden, which is the deliberate trade: an absent fan and an idle one
         * are indistinguishable through this interface.
         */
        public FanReading[] fans() {
            return _fans;
        }

        /**
         * Power rails the hardware actually measures.
         *
         * Two sources, both real readings rather than estimates:
         *   * hwmon power*_input, a direct figure in microwatts. An AMD GPU
         *     reports its package power this way (measured: amdgpu PPT 59.2 W).
         *   * INA-style shunt monitors, which publish bus voltage and current
         *     per channel but no power field. Volts x amps on the SAME channel
         *     is measurement, not synthesis, and it cross-checks: on an IGX
         *     Thor board channel 1 reads 12.08 V and 140 mA = 1.69 W, which is
         *     exactly what nvidia-smi independently reports for that GPU.
         *
         * DELIBERATELY NOT INCLUDED: Intel RAPL. /sys/class/powercap/.../
         * energy_uj is root-only on current kernels (restricted after the
         * Platypus side-channel work), so a desktop session simply cannot read
         * it -- measured here as an empty value rather than a number. It also
         * reports cumulative energy, so watts would require differencing over
         * time. Nothing is reported rather than guessed.
         */
        public PowerReading[] power_rails() {
            return _power;
        }

        private static string? read_first_line(string path) {
            string contents;
            try {
                if (!FileUtils.get_contents(path, out contents)) {
                    return null;
                }
            } catch (FileError e) {
                return null;
            }
            return contents.strip();
        }

        private static bool matches_any(string text, string[] needles) {
            string lower = text.down();
            foreach (string needle in needles) {
                if (lower.contains(needle)) {
                    return true;
                }
            }
            return false;
        }

        private SensorKind classify(string chip, string? label) {
            string joined = (label != null && label != "")
                ? chip + " " + label
                : chip;

            if (gpu_hint != "" && joined.contains(gpu_hint)) {
                return SensorKind.GPU;
            }
            if (cpu_hint != "" && joined.contains(cpu_hint)) {
                return SensorKind.CPU;
            }
            if (matches_any(chip, GPU_CHIPS)) {
                return SensorKind.GPU;
            }
            if (matches_any(chip, CPU_CHIPS)) {
                return SensorKind.CPU;
            }
            if (label != null && matches_any(label, CPU_LABELS)) {
                return SensorKind.CPU;
            }
            // Unknown is SYSTEM on purpose. See the class comment.
            return SensorKind.SYSTEM;
        }

        private SensorReading[] collect_hwmon() {
            SensorReading[] found = {};
            Dir dir;
            try {
                dir = Dir.open(HWMON_DIR, 0);
            } catch (FileError e) {
                return found;
            }
            string? node;
            while ((node = dir.read_name()) != null) {
                string base_path = HWMON_DIR + "/" + node;
                string chip = read_first_line(base_path + "/name") ?? node;
                Dir inner;
                try {
                    inner = Dir.open(base_path, 0);
                } catch (FileError e) {
                    continue;
                }
                string? entry;
                while ((entry = inner.read_name()) != null) {
                    if (!entry.has_prefix("temp") || !entry.has_suffix("_input")) {
                        continue;
                    }
                    string? raw = read_first_line(base_path + "/" + entry);
                    if (raw == null) {
                        continue;
                    }
                    int millidegrees = int.parse(raw);
                    if (millidegrees <= 0) {
                        continue;
                    }
                    string stem = entry.substring(0, entry.length - "_input".length);
                    string? label = read_first_line(base_path + "/" + stem + "_label");
                    string name = (label != null && label != "")
                        ? "%s %s".printf(chip, label)
                        : chip;
                    found += new SensorReading(name, millidegrees, classify(chip, label));
                }
            }
            return found;
        }

        private SensorReading[] collect_thermal() {
            SensorReading[] found = {};
            Dir dir;
            try {
                dir = Dir.open(THERMAL_DIR, 0);
            } catch (FileError e) {
                return found;
            }
            string? node;
            while ((node = dir.read_name()) != null) {
                if (!node.has_prefix("thermal_zone")) {
                    continue;
                }
                string base_path = THERMAL_DIR + "/" + node;
                string? zone_type = read_first_line(base_path + "/type");
                string? raw = read_first_line(base_path + "/temp");
                if (zone_type == null || raw == null) {
                    continue;
                }
                int millidegrees = int.parse(raw);
                if (millidegrees <= 0) {
                    continue;
                }
                found += new SensorReading(zone_type, millidegrees, classify(zone_type, null));
            }
            return found;
        }

        private FanReading[] collect_fans() {
            FanReading[] found = {};
            Dir dir;
            try {
                dir = Dir.open(HWMON_DIR, 0);
            } catch (FileError e) {
                return found;
            }
            string? node;
            while ((node = dir.read_name()) != null) {
                string base_path = HWMON_DIR + "/" + node;
                string chip = read_first_line(base_path + "/name") ?? node;
                Dir inner;
                try {
                    inner = Dir.open(base_path, 0);
                } catch (FileError e) {
                    continue;
                }
                string? entry;
                while ((entry = inner.read_name()) != null) {
                    if (!entry.has_prefix("fan") || !entry.has_suffix("_input")) {
                        continue;
                    }
                    string? raw = read_first_line(base_path + "/" + entry);
                    if (raw == null) {
                        continue;
                    }
                    int rpm = int.parse(raw);
                    if (rpm <= 0) {
                        continue;
                    }
                    string stem = entry.substring(0, entry.length - "_input".length);
                    string? label = read_first_line(base_path + "/" + stem + "_label");
                    string name = (label != null && label != "")
                        ? "%s %s".printf(chip, label)
                        : "%s %s".printf(chip, stem);
                    found += new FanReading(name, rpm);
                }
            }
            return found;
        }

        private PowerReading[] collect_power() {
            PowerReading[] found = {};
            Dir dir;
            try {
                dir = Dir.open(HWMON_DIR, 0);
            } catch (FileError e) {
                return found;
            }
            string? node;
            while ((node = dir.read_name()) != null) {
                string base_path = HWMON_DIR + "/" + node;
                string chip = read_first_line(base_path + "/name") ?? node;

                // 1. A direct power reading, in microwatts.
                Dir inner;
                try {
                    inner = Dir.open(base_path, 0);
                } catch (FileError e) {
                    continue;
                }
                // Channels already covered by a direct powerN_input reading.
                // Shunt drivers (INA219/ina2xx) expose BOTH that and inN/currN
                // for one physical rail, so synthesising V x I for such a
                // channel would report the same rail twice under two labels.
                bool[] direct_channel = new bool[9];
                string? entry;
                while ((entry = inner.read_name()) != null) {
                    if (!entry.has_prefix("power") || !entry.has_suffix("_input")) {
                        continue;
                    }
                    string? raw = read_first_line(base_path + "/" + entry);
                    if (raw == null) {
                        continue;
                    }
                    int64 microwatts = int64.parse(raw);
                    if (microwatts <= 0) {
                        continue;
                    }
                    string stem = entry.substring(0, entry.length - "_input".length);
                    int direct_ch = int.parse(stem.substring("power".length));
                    if (direct_ch >= 1 && direct_ch <= 8) {
                        direct_channel[direct_ch] = true;
                    }
                    string? label = read_first_line(base_path + "/" + stem + "_label");
                    string name = (label != null && label != "")
                        ? "%s %s".printf(chip, label)
                        : chip;
                    found += new PowerReading(name, (int) (microwatts / 1000));
                }

                // 2. Shunt monitors: bus volts x channel amps. hwmon numbers
                //    both from 1, so channel N pairs inN_input with currN_input.
                for (int ch = 1; ch <= 8; ch++) {
                    if (direct_channel[ch]) {
                        continue;
                    }
                    string? volt_raw = read_first_line("%s/in%d_input".printf(base_path, ch));
                    string? curr_raw = read_first_line("%s/curr%d_input".printf(base_path, ch));
                    if (volt_raw == null || curr_raw == null) {
                        continue;
                    }
                    int millivolts = int.parse(volt_raw);
                    int milliamps = int.parse(curr_raw);
                    if (millivolts <= 0 || milliamps <= 0) {
                        continue;
                    }
                    string? label = read_first_line("%s/curr%d_label".printf(base_path, ch));
                    string name = (label != null && label != "")
                        ? "%s %s".printf(chip, label)
                        : "%s ch%d".printf(chip, ch);
                    found += new PowerReading(name, (millivolts * milliamps) / 1000);
                }
            }
            return found;
        }

        /**
         * CPU MHz as reported by /proc/cpuinfo.
         *
         * Used when cpufreq yields nothing -- either because the directory is
         * absent (common on virtual machines and on x86 with no scaling driver)
         * or because it exists but is empty / has no readable scaling_cur_freq.
         */
        private int[] clocks_from_cpuinfo() {
            int[] found = {};
            string? cpuinfo = read_first_line("/proc/cpuinfo");
            if (cpuinfo == null) {
                return found;
            }
            foreach (string line in cpuinfo.split("\n")) {
                if (!line.down().has_prefix("cpu mhz")) {
                    continue;
                }
                string[] parts = line.split(":");
                if (parts.length < 2) {
                    continue;
                }
                int mhz = (int) double.parse(parts[1].strip());
                if (mhz > 0) {
                    found += mhz * 1000;
                }
            }
            return found;
        }

        private int[] collect_clocks() {
            int[] found = {};
            Dir dir;
            try {
                dir = Dir.open(CPUFREQ_DIR, 0);
            } catch (FileError e) {
                return clocks_from_cpuinfo();
            }
            string? node;
            while ((node = dir.read_name()) != null) {
                if (!node.has_prefix("policy")) {
                    continue;
                }
                string? raw = read_first_line(CPUFREQ_DIR + "/" + node + "/scaling_cur_freq");
                if (raw == null) {
                    continue;
                }
                int khz = int.parse(raw);
                if (khz > 0) {
                    found += khz;
                }
            }
            // A present cpufreq directory can still yield nothing: no policy*
            // entries, or policies whose scaling_cur_freq is unreadable. Fall
            // back on the same source as the absent-directory case.
            if (found.length == 0) {
                return clocks_from_cpuinfo();
            }
            return found;
        }


        /**
         * True when this machine has an NVIDIA driver and nvidia-smi. Checked
         * once: the answer cannot change without a driver reload, and probing
         * every tick would spawn a process just to learn "no".
         */
        private bool nvidia_available() {
            if (_nvidia_checked) {
                return _nvidia_present;
            }
            _nvidia_checked = true;
            _nvidia_present = FileUtils.test("/proc/driver/nvidia", FileTest.IS_DIR)
                && Environment.find_program_in_path("nvidia-smi") != null;
            return _nvidia_present;
        }

        private void parse_nvidia(string? csv) {
            SensorReading[] found = {};
            int power_milliwatts = -1;
            if (csv == null) {
                _nvidia_readings = found;
                gpu_power_milliwatts = -1;
                return;
            }
            foreach (string line in csv.split("\n")) {
                if (line.strip() == "") {
                    continue;
                }
                string[] fields = line.split(",");
                if (fields.length < 2) {
                    continue;
                }
                string name = fields[0].strip();
                int celsius = int.parse(fields[1].strip());
                if (celsius <= 0) {
                    continue;
                }
                found += new SensorReading(name, celsius * 1000, SensorKind.GPU);
                if (fields.length >= 4) {
                    // Fields can read "[N/A]" -- an integrated Thor GPU reports
                    // no SM clock. double.parse yields 0 there, which the
                    // guard below discards.
                    double watts = double.parse(fields[3].strip());
                    if (watts > 0.0) {
                        int milliwatts = (int) (watts * 1000.0);
                        if (milliwatts > power_milliwatts) {
                            power_milliwatts = milliwatts;
                        }
                    }
                }
            }
            _nvidia_readings = found;
            gpu_power_milliwatts = power_milliwatts;
        }

        /**
         * Query nvidia-smi off-thread. Spawned via Subprocess.newv rather than a
         * shell, and never waited on: the result lands on a later tick, so a
         * slow or wedged driver cannot stall the UI.
         */
        private void refresh_nvidia() {
            if (!nvidia_available() || _nvidia_in_flight) {
                return;
            }
            string[] argv = {
                "nvidia-smi",
                "--query-gpu=name,temperature.gpu,clocks.sm,power.draw",
                "--format=csv,noheader,nounits"
            };
            try {
                Subprocess proc = new Subprocess.newv(
                    argv, SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_SILENCE);
                _nvidia_in_flight = true;
                proc.communicate_utf8_async.begin(null, null, (obj, res) => {
                    string? stdout_text = null;
                    try {
                        proc.communicate_utf8_async.end(res, out stdout_text, null);
                    } catch (Error e) {
                        stdout_text = null;
                    }
                    parse_nvidia(stdout_text);
                    _nvidia_in_flight = false;
                    // Publish what just arrived. Without this a one-shot
                    // refresh() never reports an NVIDIA GPU, and a timer-driven
                    // caller sees it only on the following tick. This merges the
                    // cached sysfs readings rather than calling refresh() again,
                    // so completing a query cannot start another one and does not
                    // re-walk every hwmon and thermal node.
                    publish_state();
                });
            } catch (Error e) {
                // Driver present but the tool failed: stop asking.
                _nvidia_present = false;
                _nvidia_in_flight = false;
            }
        }

        /**
         * Whether two sensor names refer to the same thing.
         *
         * Compared with separators and case removed, because the SAME sensor is
         * routinely spelled differently by the two interfaces. MEASURED on a
         * Raspberry Pi 5: hwmon calls it "cpu_thermal" and the thermal zone
         * calls it "cpu-thermal", so an exact comparison listed one 53 C sensor
         * twice.
         */
        private static bool same_sensor(string a, string b) {
            return a.down().replace("-", "").replace("_", "").replace(" ", "")
                == b.down().replace("-", "").replace("_", "").replace(" ", "");
        }

        public void refresh() {
            refresh_internal(true);
        }

        private void refresh_internal(bool query_nvidia) {
            // BOTH sources, always -- not hwmon-with-thermal-as-fallback.
            // MEASURED on an NVIDIA IGX Thor dev kit: hwmon exists there, but
            // contains only a Super-I/O chip, INA power monitors, the NIC and
            // the NVMe -- no CPU or GPU temperature at all. The CPU and GPU
            // live in /sys/class/thermal as cpu-thermal and gpu-thermal. A
            // "use thermal only when hwmon is empty" rule therefore reported NO
            // CPU on that machine, because hwmon was non-empty but useless.
            // Thermal zones that merely duplicate an hwmon chip are dropped.
            SensorReading[] found = collect_hwmon();
            foreach (SensorReading zone in collect_thermal()) {
                bool duplicate = false;
                foreach (SensorReading existing in found) {
                    if (same_sensor(existing.label, zone.label)) {
                        duplicate = true;
                        break;
                    }
                }
                if (!duplicate) {
                    found += zone;
                }
            }
            // Keep the sysfs-derived set separate from the NVIDIA set: when the
            // async query lands, publish_state() can merge the two again without
            // re-walking every hwmon and thermal node.
            SensorReading[] base_found = found;

            // NVIDIA readings arrive asynchronously, so this merges whatever the
            // last query returned rather than waiting for a fresh one.
            if (query_nvidia) {
                refresh_nvidia();
            }
            _base_readings = base_found;

            _fans = collect_fans();
            _power = collect_power();

            int[] clocks = collect_clocks();
            // Highest first, so a caller can take element 0 as "the" clock.
            if (clocks.length > 1) {
                for (int i = 0; i < clocks.length; i++) {
                    for (int j = i + 1; j < clocks.length; j++) {
                        if (clocks[j] > clocks[i]) {
                            int swap = clocks[i];
                            clocks[i] = clocks[j];
                            clocks[j] = swap;
                        }
                    }
                }
            }
            _clocks_khz = clocks;

            publish_state();
        }

        /**
         * Recompute the published properties from the cached reading sets and
         * emit updated().
         *
         * Split out of refresh_internal() so the asynchronous nvidia-smi
         * callback can publish its result without re-walking every hwmon and
         * thermal node -- it merges _base_readings with the NVIDIA set instead.
         */
        private void publish_state() {
            SensorReading[] found = _base_readings;
            foreach (SensorReading reading in _nvidia_readings) {
                found += reading;
            }
            _readings = found;

            int hottest_cpu = -1;
            int hottest_gpu = -1;
            int hottest_system = -1;
            foreach (SensorReading reading in found) {
                switch (reading.kind) {
                    case SensorKind.CPU:
                        if (reading.millidegrees > hottest_cpu) {
                            hottest_cpu = reading.millidegrees;
                        }
                        break;
                    case SensorKind.GPU:
                        if (reading.millidegrees > hottest_gpu) {
                            hottest_gpu = reading.millidegrees;
                        }
                        break;
                    default:
                        if (reading.millidegrees > hottest_system) {
                            hottest_system = reading.millidegrees;
                        }
                        break;
                }
            }

            cpu_millidegrees = hottest_cpu;
            gpu_millidegrees = hottest_gpu;
            system_millidegrees = hottest_system;
            cpu_khz = _clocks_khz.length > 0 ? _clocks_khz[0] : -1;
            // Any readable category counts. A VM or a restricted-hwmon setup
            // can expose clocks, fans or power rails with no temperature at all;
            // reporting "nothing readable" there would hide real data.
            available = found.length > 0
                || _clocks_khz.length > 0
                || _fans.length > 0
                || _power.length > 0;

            updated();
        }
    }
}