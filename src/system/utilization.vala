using GLib;

namespace Singularity {

    /**
     * One utilisation figure -- a fraction of some resource in use right now.
     *
     * Deliberately separate from SensorReading. A temperature is an absolute
     * measurement that is meaningful on its own; a utilisation is a ratio that
     * is meaningless without the window it was measured over. Sharing one type
     * would have forced every consumer to ask which of the two it was holding.
     */
    public class UtilizationReading : Object {
        public string label { get; private set; }
        public SensorKind kind { get; private set; }

        /**
         * 0.0 to 1.0, or -1.0 when NOT YET KNOWN.
         *
         * CPU and disk utilisation are computed from the DELTA between two
         * samples, so the very first sample after start() cannot produce one.
         * -1.0 says so explicitly. Reporting 0.0 there would be indistinguish-
         * able from a genuinely idle machine, and the panel would show a
         * confident "CPU 0%" for one whole interval on every open.
         */
        public double fraction { get; private set; }

        public UtilizationReading(string label, SensorKind kind, double fraction) {
            this.label = label;
            this.kind = kind;
            this.fraction = fraction;
        }
    }

    /**
     * One mounted filesystem's space usage.
     *
     * Carries the absolute byte counts alongside the ratio because "83% full"
     * means something very different on a 512 MB ESP than on a 4 TB array, and
     * the caller is the only one that knows which it wants to show.
     */
    public class CapacityReading : Object {
        public string label { get; private set; }
        public uint64 used_bytes { get; private set; }
        public uint64 total_bytes { get; private set; }

        public CapacityReading(string label, uint64 used_bytes, uint64 total_bytes) {
            this.label = label;
            this.used_bytes = used_bytes;
            this.total_bytes = total_bytes;
        }

        /** 0.0 to 1.0; -1.0 when the filesystem reports no size. */
        public double fraction {
            get {
                if (total_bytes == 0) {
                    return -1.0;
                }
                double f = (double) used_bytes / (double) total_bytes;
                return f > 1.0 ? 1.0 : f;
            }
        }
    }

    /** A /proc/stat CPU line, reduced to the two totals a ratio needs. */
    private class CpuSample {
        public int64 idle;
        public int64 total;
    }

    /** A /proc/diskstats device, reduced to its busy-time counter. */
    private class DiskSample {
        public int64 io_ticks_ms;
    }

    /**
     * Samples CPU, memory and disk utilisation from /proc.
     *
     * Sibling to SensorMonitor rather than part of it: SensorMonitor reads
     * absolute values out of sysfs and is stateless between polls, while every
     * figure here except memory is a rate that requires the previous sample.
     * Folding rate state into SensorMonitor would have made its start/stop a
     * correctness requirement rather than a power optimisation.
     */
    public class UtilizationMonitor : Object {

        /**
         * Root to read /proc from. Empty means the real one.
         *
         * Exists for the same reason SensorMonitor.sysfs_root does: these
         * parsers have to cope with layouts from machines that are not the one
         * running the test, and a fixture tree is the only way to hold several
         * of them at once.
         */
        public string proc_root { get; set; default = ""; }

        /** Poll period. Matched to the sensors panel's default. */
        public int interval_seconds { get; set; default = 2; }

        /**
         * Hard ceiling on rows returned by per_cpu() and disks().
         *
         * Sky1 exposes 12 CPUs and a machine with several NVMe devices plus
         * dm- mappings can list a dozen more. An unbounded list rendered into
         * a plain box grows past the bottom of the monitor; capping at the
         * source means no caller can forget.
         */
        public const int MAX_ROWS = 32;

        public signal void updated();

        private uint _timer_id = 0;

        private CpuSample? _prev_cpu_total = null;
        private CpuSample[] _prev_cpu_each = {};
        private int64 _prev_disk_time_us = 0;
        private Gee.HashMap<string, DiskSample> _prev_disks =
            new Gee.HashMap<string, DiskSample>();

        private double _cpu_fraction = -1.0;
        private UtilizationReading[] _per_cpu = {};
        private double _memory_fraction = -1.0;
        private uint64 _mem_used_bytes = 0;
        private uint64 _mem_total_bytes = 0;
        private double _swap_fraction = -1.0;
        private UtilizationReading[] _disks = {};
        private CapacityReading[] _filesystems = {};

        public UtilizationMonitor() {}

        /** Aggregate CPU busy fraction; -1.0 until two samples exist. */
        public double cpu_fraction { get { return _cpu_fraction; } }

        /** Fraction of RAM in use (MemTotal - MemAvailable); -1.0 if unread. */
        public double memory_fraction { get { return _memory_fraction; } }

        public uint64 memory_used_bytes  { get { return _mem_used_bytes; } }
        public uint64 memory_total_bytes { get { return _mem_total_bytes; } }

        /** Fraction of swap in use; -1.0 when there is no swap at all. */
        public double swap_fraction { get { return _swap_fraction; } }

        public UtilizationReading[] per_cpu()     { return _per_cpu; }
        public UtilizationReading[] disks()       { return _disks; }
        public CapacityReading[]    filesystems() { return _filesystems; }

        public void start() {
            if (_timer_id != 0) {
                return;
            }
            // Drop rate state so a stop/start pair cannot produce a spike from
            // a delta measured across the gap. A panel that was closed for an
            // hour would otherwise report one interval of nonsense on reopen.
            _prev_cpu_total = null;
            _prev_cpu_each = {};
            _prev_disks.clear();
            _prev_disk_time_us = 0;
            _cpu_fraction = -1.0;

            _timer_id = Timeout.add_seconds(interval_seconds, () => {
                poll();
                return Source.CONTINUE;
            });
            poll();
        }

        public void stop() {
            if (_timer_id != 0) {
                Source.remove(_timer_id);
                _timer_id = 0;
            }
        }

        public bool running { get { return _timer_id != 0; } }

        private string proc_path(string name) {
            if (proc_root == "") {
                return "/proc/" + name;
            }
            return Path.build_filename(proc_root, "proc", name);
        }

        /** One sampling pass. Public so a caller can force a refresh. */
        public void poll() {
            read_cpu();
            read_memory();
            read_disks();
            read_filesystems();
            updated();
        }

        // ---- CPU ----------------------------------------------------------

        private void read_cpu() {
            var f = FileStream.open(proc_path("stat"), "r");
            if (f == null) {
                return;
            }

            CpuSample? total = null;
            CpuSample[] each = {};
            string[] each_labels = {};

            string? line;
            while ((line = f.read_line()) != null) {
                if (!line.has_prefix("cpu")) {
                    continue;
                }
                string[] parts = Regex.split_simple("[ \t]+", line.strip());
                if (parts.length < 5) {
                    continue;
                }
                CpuSample s = parse_cpu_fields(parts);
                if (parts[0] == "cpu") {
                    total = s;
                } else if (each.length < MAX_ROWS) {
                    each += s;
                    each_labels += parts[0];
                }
            }

            if (total != null) {
                _cpu_fraction = busy_fraction(_prev_cpu_total, total);
                _prev_cpu_total = total;
            }

            UtilizationReading[] readings = {};
            for (int i = 0; i < each.length; i++) {
                double frac = i < _prev_cpu_each.length
                    ? busy_fraction(_prev_cpu_each[i], each[i])
                    : -1.0;
                readings += new UtilizationReading(each_labels[i], SensorKind.CPU, frac);
            }
            _per_cpu = readings;
            _prev_cpu_each = each;
        }

        /**
         * Sum a /proc/stat cpu line into idle and total jiffies.
         *
         * Fields are user nice system idle iowait irq softirq steal guest
         * guest_nice. iowait counts as IDLE: the CPU is not executing during
         * it, and folding it into busy makes a machine waiting on a slow disk
         * look pegged. Trailing fields are summed generically so a kernel that
         * adds another one does not silently skew the total.
         */
        private CpuSample parse_cpu_fields(string[] parts) {
            var s = new CpuSample();
            for (int i = 1; i < parts.length; i++) {
                int64 v = int64.parse(parts[i]);
                if (v < 0) {
                    continue;
                }
                s.total += v;
                if (i == 4 || i == 5) {   // idle, iowait
                    s.idle += v;
                }
            }
            return s;
        }

        /** Busy fraction between two samples; -1.0 when it cannot be formed. */
        private double busy_fraction(CpuSample? prev, CpuSample now) {
            if (prev == null) {
                return -1.0;
            }
            int64 d_total = now.total - prev.total;
            int64 d_idle  = now.idle  - prev.idle;
            // A negative delta means the counter went backwards -- CPU hotplug
            // or a fixture swap. Report unknown rather than a wild number.
            if (d_total <= 0 || d_idle < 0) {
                return -1.0;
            }
            double f = 1.0 - ((double) d_idle / (double) d_total);
            if (f < 0.0) return 0.0;
            if (f > 1.0) return 1.0;
            return f;
        }

        // ---- memory -------------------------------------------------------

        private void read_memory() {
            var f = FileStream.open(proc_path("meminfo"), "r");
            if (f == null) {
                return;
            }
            int64 mem_total = 0, mem_available = 0;
            int64 swap_total = 0, swap_free = 0;
            string? line;
            while ((line = f.read_line()) != null) {
                if (line.has_prefix("MemTotal:")) {
                    mem_total = parse_meminfo_kb(line);
                } else if (line.has_prefix("MemAvailable:")) {
                    mem_available = parse_meminfo_kb(line);
                } else if (line.has_prefix("SwapTotal:")) {
                    swap_total = parse_meminfo_kb(line);
                } else if (line.has_prefix("SwapFree:")) {
                    swap_free = parse_meminfo_kb(line);
                }
            }

            if (mem_total > 0) {
                // MemAvailable, not MemFree: free excludes reclaimable page
                // cache, so a healthy Linux box reads as ~95% full all the
                // time and the figure stops carrying information.
                int64 used = mem_total - mem_available;
                if (used < 0) used = 0;
                _mem_total_bytes = (uint64) mem_total * 1024;
                _mem_used_bytes  = (uint64) used * 1024;
                _memory_fraction = (double) used / (double) mem_total;
            }

            // No swap configured is not an error and must not read as 0% used;
            // -1.0 lets the caller omit the row entirely.
            _swap_fraction = swap_total > 0
                ? (double) (swap_total - swap_free) / (double) swap_total
                : -1.0;
        }

        private int64 parse_meminfo_kb(string line) {
            string[] parts = Regex.split_simple("[ \t]+", line.strip());
            return parts.length >= 2 ? int64.parse(parts[1]) : 0;
        }

        // ---- disk I/O ------------------------------------------------------

        /**
         * Per-device busy percentage from /proc/diskstats.
         *
         * Field 10 (io_ticks, index 12 on the split line) is milliseconds
         * during which the queue was non-empty. Divided by the wall-clock
         * milliseconds since the last sample it is exactly what iostat prints
         * as %util. Wall clock comes from the monotonic clock, not from the
         * poll interval, because a late timer would otherwise inflate the
         * result above 100%.
         */
        private void read_disks() {
            var f = FileStream.open(proc_path("diskstats"), "r");
            if (f == null) {
                return;
            }

            int64 now_us = GLib.get_monotonic_time();
            int64 elapsed_ms = _prev_disk_time_us > 0
                ? (now_us - _prev_disk_time_us) / 1000
                : 0;

            UtilizationReading[] readings = {};
            var current = new Gee.HashMap<string, DiskSample>();

            string? line;
            while ((line = f.read_line()) != null) {
                string[] parts = Regex.split_simple("[ \t]+", line.strip());
                if (parts.length < 13) {
                    continue;
                }
                string name = parts[2];
                if (!is_interesting_block_device(name)) {
                    continue;
                }

                var s = new DiskSample();
                s.io_ticks_ms = int64.parse(parts[12]);
                current.set(name, s);

                if (readings.length >= MAX_ROWS) {
                    continue;
                }

                double frac = -1.0;
                DiskSample? prev = _prev_disks.get(name);
                if (prev != null && elapsed_ms > 0) {
                    int64 d = s.io_ticks_ms - prev.io_ticks_ms;
                    if (d >= 0) {
                        frac = (double) d / (double) elapsed_ms;
                        if (frac > 1.0) frac = 1.0;
                    }
                }
                readings += new UtilizationReading(name, SensorKind.STORAGE, frac);
            }

            _disks = readings;
            _prev_disks = current;
            _prev_disk_time_us = now_us;
        }

        /**
         * Whole storage devices only.
         *
         * Partitions are excluded because their busy time is the parent's,
         * counted again -- listing nvme0n1, nvme0n1p1 and nvme0n1p2 shows one
         * disk three times. loop and ram devices are excluded because a
         * squashfs-backed live image has dozens of them and none is a disk.
         * /sys/block/<name> is the kernel's own answer to "is this a whole
         * device", so we ask it rather than pattern-matching trailing digits,
         * which gets nvme0n1 wrong.
         */
        private bool is_interesting_block_device(string name) {
            if (name.has_prefix("loop") || name.has_prefix("ram") ||
                name.has_prefix("zram") || name.has_prefix("sr")) {
                return false;
            }
            string block = proc_root == ""
                ? "/sys/block/" + name
                : Path.build_filename(proc_root, "sys", "block", name);
            return FileUtils.test(block, FileTest.EXISTS);
        }

        // ---- filesystem capacity -------------------------------------------

        /**
         * Space used per mounted filesystem.
         *
         * Pseudo filesystems are filtered via GUnixMountEntry when reading
         * the real /proc/mounts (the static rule list inside glib is
         * broader than the hand-maintained one this used to carry), and via
         * a small fstype table when reading a fixture tree under proc_root
         * -- glib reads the real /proc and would ignore the fixture. See
         * is_real_filesystem for the device-path overrides that keep a
         * mounted root disk visible and the iso9660 / udf / erofs / loop
         * rules that keep alarm-coloured disk images out. Devices are
         * de-duplicated so a bind mount does not report the same storage
         * twice.
         */
        private void read_filesystems() {
            var f = FileStream.open(proc_path("mounts"), "r");
            if (f == null) {
                return;
            }

            CapacityReading[] readings = {};
            var seen_devices = new Gee.HashSet<string>();

            string? line;
            while ((line = f.read_line()) != null) {
                string[] parts = Regex.split_simple("[ \t]+", line.strip());
                if (parts.length < 3) {
                    continue;
                }
                string device = parts[0];
                string mount_point = parts[1].compress();  // \040 -> space
                string fstype = parts[2];

                if (!is_real_filesystem(fstype, device, mount_point)) {
                    continue;
                }
                if (!seen_devices.add(device)) {
                    continue;
                }
                if (readings.length >= MAX_ROWS) {
                    break;
                }

                try {
                    var info = File.new_for_path(mount_point)
                        .query_filesystem_info("filesystem::size,filesystem::used", null);
                    uint64 size = info.get_attribute_uint64("filesystem::size");
                    if (size == 0) {
                        continue;
                    }
                    uint64 used = info.get_attribute_uint64("filesystem::used");
                    readings += new CapacityReading(mount_point, used, size);
                } catch (Error e) {
                    // An unreadable mount is normal -- an autofs point that is
                    // not triggered, or another user's namespace. Skip it; it
                    // is not an error worth surfacing in a panel.
                    continue;
                }
            }

            _filesystems = readings;
        }

        private bool is_real_filesystem(string fstype, string device, string mount_point) {
            // Mounted disk images are always 100% full -- an image is written
            // full and never grows -- so a row that can only ever say "100%"
            // is alarm-coloured noise. GUnixMountEntry cannot know this is a
            // product decision about what to display, so the check stays.
            if (fstype == "iso9660" || fstype == "udf" || fstype == "erofs") {
                return false;
            }

            // A loop mount is a FILE inside some other filesystem, and that
            // filesystem is already listed. Counting it again reports the same
            // bytes twice. Same reasoning as above -- a presentation rule that
            // GUnixMountEntry cannot recover from its mount-table data.
            if (device.has_prefix("/dev/loop")) {
                return false;
            }

            // A real filesystem is backed by something in /dev (block device)
            // or named like a network share (host:/path, user@host:/path).
            // GUnixMountEntry.is_system_internal() also flags "/" itself as
            // internal (its hard-coded system_mount_paths list contains "/",
            // reasoning that file managers already have a "Filesystem root"
            // entry and do not also need it as a mount). For a capacity
            // panel this is wrong -- the root disk is the one the user most
            // wants to see -- so when the device shape has already said
            // "looks like a real disk" we trust that and skip glib.
            if (device.has_prefix("/dev/") || device.contains(":")) {
                return true;
            }

            // Pseudo-filesystem detection, consulted only when the device
            // shape has not already said "looks like a real disk".
            // GUnixMountEntry is wider than the old hand-maintained list
            // (it covers /dev/loop, devpts, ...), but its rules are
            // incomplete for fuse.* / snapfuse (not flagged as internal) and
            // it has no way to know about the iso9660 / udf / erofs product
            // rule above.
            //
            // Two code paths exist because GUnixMountEntry reads the REAL
            // /proc/mounts and has no override hook: when proc_root is set
            // (fixture tests, see tests/utilization_test.vala) glib would
            // query the host and ignore the synthetic mounts we wrote, so
            // we fall back to the hand-maintained fstype list. When
            // proc_root is empty we are reading the real /proc/mounts, so
            // we can ask glib directly.
            if (proc_root == "") {
                // Vala 0.56 binds g_unix_mount_for() as a constructor named
                // "@for"; the second argument is the table-read timestamp
                // out-param that the C prototype requires.
                uint64 time_read;
                var entry = new GLib.UnixMountEntry.@for(mount_point, out time_read);
                if (entry != null && entry.is_system_internal()) {
                    return false;
                }
            } else if (fstype_is_pseudo(fstype)) {
                return false;
            }

            return false;
        }

        /**
         * Hand-maintained fstype list, used only when reading a fixture
         * /proc/mounts (see the dual-path comment in is_real_filesystem).
         * Mirrors what GUnixMountEntry.is_system_internal() would answer on a
         * real system, so the fixture tests assert against the same shapes.
         */
        private static bool fstype_is_pseudo(string fstype) {
            switch (fstype) {
                case "proc": case "sysfs": case "devtmpfs": case "devpts":
                case "tmpfs": case "ramfs": case "cgroup": case "cgroup2":
                case "securityfs": case "pstore": case "efivarfs": case "bpf":
                case "debugfs": case "tracefs": case "configfs": case "fusectl":
                case "mqueue": case "hugetlbfs": case "binfmt_misc": case "autofs":
                case "rpc_pipefs": case "nsfs": case "squashfs": case "overlay":
                    return true;
            }
            return false;
        }
    }
}
