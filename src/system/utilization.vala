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
         * Filesystem capacity poll period.
         *
         * Defaults to 60 seconds, not the 2 s of interval_seconds. The CPU
         * panel is a rate: two seconds of jiffies is the granularity the
         * figure is meaningful at. Disk usage is a stock level: even a busy
         * nightly rsync moves the bar a fraction of a percent, and the cost
         * of the round trip is wildly uneven -- a local ext4 statfs returns
         * in microseconds, but an unreachable NFS/CIFS share blocks until
         * the kernel's RPC timeout (60-180 s on a default Linux box).
         * Probing it 30 times a minute to learn something that changes by
         * minutes is wasted, and at the 2 s cadence a single unresponsive
         * mount would freeze the main loop every poll. 60 s keeps the figure
         * fresh enough for a panel and keeps the worst case at one slow
         * round trip per minute per mount, never on the main thread.
         */
        public int fs_interval_seconds { get; set; default = 60; }

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
        private Gee.HashMap<string, CpuSample> _prev_cpu_each =
            new Gee.HashMap<string, CpuSample>();
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

        // ---- async filesystem refresh state ------------------------------
        //
        // Capacity probing moved off the main loop and onto its own timer
        // (see fs_interval_seconds). These fields are its bookkeeping: the
        // cancellable for the in-flight probes, the mount points currently
        // being queried so we never queue two probes at the same mount, a
        // cache of last-known readings so a single failed probe does not
        // vanish from the panel, and per-mount monotonic timestamps of the
        // last failure for backoff so a wedged NFS share is not re-probed
        // every fs_interval_seconds and stays one slow round trip per
        // failure window, not one per panel tick.
        private uint _fs_timer_id = 0;
        private GLib.Cancellable? _fs_cancellable = null;
        private Gee.HashSet<string> _fs_in_flight = new Gee.HashSet<string>();
        private Gee.HashMap<string, CapacityReading> _fs_known =
            new Gee.HashMap<string, CapacityReading>();
        private Gee.HashMap<string, int64?> _fs_failed_at =
            new Gee.HashMap<string, int64?>();

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
            _prev_cpu_each.clear();
            _prev_disks.clear();
            _prev_disk_time_us = 0;
            _cpu_fraction = -1.0;

            _timer_id = Timeout.add_seconds(interval_seconds, () => {
                poll();
                return Source.CONTINUE;
            });

            // Capacity refresh lives on its own, slower timer (see
            // fs_interval_seconds). It is dispatched ASYNCHRONOUSLY so an
            // unreachable NFS/CIFS share can never freeze the main loop --
            // query_filesystem_info() against such a mount blocks until the
            // kernel's RPC timeout, and calling it from poll() every two
            // seconds was the maintainer-flagged hang risk. A fresh cycle
            // is also kicked immediately so a panel that just opened does
            // not wait fs_interval_seconds for the first bar.
            if (_fs_cancellable == null || _fs_cancellable.is_cancelled()) {
                _fs_cancellable = new GLib.Cancellable();
            }
            schedule_filesystems_timer();

            poll();
            kick_filesystems();
        }

        public void stop() {
            if (_timer_id != 0) {
                Source.remove(_timer_id);
                _timer_id = 0;
            }
            // Cancel anything in flight so a slow NFS probe does not
            // outlive the monitor and so dispose() can rely on stop()
            // actually quietening the channel. _fs_in_flight and _fs_known
            // are kept on purpose: a caller that reads filesystems() right
            // after stop() still gets the last reported numbers, and the
            // in-flight set will be cleared by the cancelled callbacks when
            // they eventually fire (or simply discarded by the next start).
            if (_fs_timer_id != 0) {
                Source.remove(_fs_timer_id);
                _fs_timer_id = 0;
            }
            if (_fs_cancellable != null && !_fs_cancellable.is_cancelled()) {
                _fs_cancellable.cancel();
            }
        }

        /**
         * Mirror SensorMonitor.dispose() so a caller using `using
         * UtilisationMonitor` or `Object @ref` semantics gets the same
         * teardown contract: stop the timers and cancel any in-flight
         * filesystem probe so the destructor is synchronous from the UI's
         * point of view.
         */
        public override void dispose() {
            stop();
            base.dispose();
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
            // Filesystem capacity probing is intentionally NOT done here.
            // query_filesystem_info() is synchronous and on an unreachable
            // NFS/CIFS mount it blocks until the kernel RPC timeout, which
            // is minutes -- a hang in the middle of the UI's main loop. The
            // capacity refresh is dispatched asynchronously on its own
            // slower timer; see kick_filesystems() and the fs_interval_seconds
            // property for the cadence and rationale.
            updated();
        }

        /**
         * Force a filesystem capacity refresh now.
         *
         * Public counterpart to the internal timer, so a panel that just
         * expanded or a user that just clicked "refresh" can pull fresh
         * numbers without waiting fs_interval_seconds. Returns immediately;
         * results land asynchronously via the existing query_filesystem_info_async
         * path. Repeated calls inside one refresh window are coalesced by
         * the in-flight set -- see kick_filesystems().
         */
        public void refresh_filesystems() {
            kick_filesystems();
        }

        /**
         * Read /proc/mounts synchronously and dispatch one async probe per
         * real, de-duplicated mount.
         *
         * The mount-table read itself is a local file (the same one
         * read_disks already opens) and does not touch the network, so it
         * is safe on the main loop. The probe per mount is what blocks on
         * an unreachable share, and that is the call handed to GIO's async
         * API below.
         */
        private void kick_filesystems() {
            var f = FileStream.open(proc_path("mounts"), "r");
            if (f == null) {
                return;
            }

            // Cycle-local cancel source: every probe in this round ties its
            // cancellable to _fs_cancellable so a stop() can abort the lot
            // at once. _fs_in_flight is the per-mount guard that prevents
            // two overlapping probes for the same mount -- it is checked
            // and added together so a re-entry cannot squeeze in between.
            if (_fs_cancellable == null || _fs_cancellable.is_cancelled()) {
                _fs_cancellable = new GLib.Cancellable();
            }
            GLib.Cancellable cycle_cancel = _fs_cancellable;

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
                // The in-flight set is checked BEFORE the failure-backoff
                // check below: if a probe is already pending for this mount
                // the spec says we must not queue another, regardless of
                // whether that probe is on its first try or its nth
                // post-failure retry.
                if (_fs_in_flight.contains(mount_point)) {
                    continue;
                }
                // Backoff: a mount whose last probe failed is left alone
                // until the backoff window passes. Without this a wedged
                // NFS share would have one slow round trip issued every
                // fs_interval_seconds for the entire life of the monitor,
                // which simply wastes the RPC timeout. The window is five
                // minutes by default (5 * fs_interval_seconds), which is
                // long enough to absorb a transient network blip and short
                // enough that a recovered share self-heals within the same
                // panel lifetime.
                int64 now_us = GLib.get_monotonic_time();
                int64? failed_at = _fs_failed_at.get(mount_point);
                if (failed_at != null) {
                    int64 backoff_us = (int64) fs_interval_seconds * 5 * 1000000;
                    if (now_us - failed_at < backoff_us) {
                        continue;
                    }
                }

                _fs_in_flight.add(mount_point);
                probe_one_filesystem.begin(mount_point, cycle_cancel);
            }
        }

        /**
         * The async probe itself. Wrapped as a Vala async method so the
         * GIO callback can be expressed inline and so the error path
         * (cancellation, IO error, missing reply) is a single try/catch
         * instead of nested callback pyramids. The actual blocking call,
         * query_filesystem_info_async().end(), is where an unreachable
         * share would otherwise freeze: with the async API the kernel can
         * do its RPC wait off the main loop and we re-enter only when
         * there is a result -- or an error -- to react to.
         *
         * The in-flight entry for this mount is removed in a finally so
         * every exit path frees the slot: success, IO error, and the
         * cancellation that stop()/dispose() issues. Without it, a
         * cancelled probe would leave the mount blocked out of the next
         * cycle and a recovered share would never be re-probed until the
         * monitor was restarted.
         */
        private async void probe_one_filesystem(string mount_point,
                                                GLib.Cancellable cancel) {
            try {
                FileInfo? info = null;
                try {
                    // io_priority = Priority.DEFAULT (0): a capacity probe has
                    // no business jumping the queue ahead of the UI's own I/O.
                    info = yield File.new_for_path(mount_point)
                        .query_filesystem_info_async(
                            "filesystem::size,filesystem::used",
                            GLib.Priority.DEFAULT, cancel);
                } catch (Error e) {
                    // Cancellation is the stop()/dispose() path -- do not
                    // record it as a failure that would feed the backoff
                    // window, and do not rebuild the published list: another
                    // cycle will repopulate it when start() runs again.
                    if (cancel.is_cancelled()) {
                        return;
                    }
                    // A real failure (mount unreachable, transport hung up,
                    // autofs not triggered, ...). Record the timestamp so
                    // the backoff in kick_filesystems() skips this mount for
                    // the next five windows, and leave the previously-known
                    // reading in place rather than yanking the row -- a
                    // panel that has been showing "CIFS share: 72%" should
                    // not blink the row out of existence every
                    // fs_interval_seconds while the share is flaky.
                    _fs_failed_at.set(mount_point, GLib.get_monotonic_time());
                    publish_filesystems();
                    return;
                }

                if (info == null) {
                    _fs_failed_at.set(mount_point, GLib.get_monotonic_time());
                    publish_filesystems();
                    return;
                }

                uint64 size = info.get_attribute_uint64("filesystem::size");
                if (size == 0) {
                    // Same rule as the synchronous version: a filesystem
                    // that reports no size is not a useful row. Forget the
                    // cached value so a subsequent probe that returns a
                    // real size becomes visible immediately, rather than
                    // waiting out the backoff.
                    _fs_known.unset(mount_point);
                    _fs_failed_at.unset(mount_point);
                    publish_filesystems();
                    return;
                }

                uint64 used = info.get_attribute_uint64("filesystem::used");
                _fs_known.set(mount_point,
                              new CapacityReading(mount_point, used, size));
                _fs_failed_at.unset(mount_point);
                publish_filesystems();
            } finally {
                // Every exit path -- success, IO error, cancellation --
                // frees the in-flight slot. See the method comment.
                _fs_in_flight.remove(mount_point);
            }
        }

        /**
         * Recompute the published _filesystems array from the cache of
         * last-known readings and emit updated() once per probe completion
         * (not once per cycle). The cache is the source of truth so a
         * probe that errors does NOT remove its row -- the row simply
         * stays at whatever it was last successful at.
         */
        private void publish_filesystems() {
            CapacityReading[] rows = {};
            foreach (var entry in _fs_known) {
                rows += entry.value;
            }
            _filesystems = rows;
            updated();
        }

        /**
         * (Re)install the filesystem-refresh timer.
         *
         * Idempotent: removing a zero _fs_timer_id is a no-op. Called
         * from start() once; stop() removes the source.
         */
        private void schedule_filesystems_timer() {
            if (_fs_timer_id != 0) {
                Source.remove(_fs_timer_id);
                _fs_timer_id = 0;
            }
            _fs_timer_id = Timeout.add_seconds(fs_interval_seconds, () => {
                kick_filesystems();
                return Source.CONTINUE;
            });
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

            // Matched by cpuN label, not array position, the same as disks
            // below -- CPU hotplug (offlining a lower-numbered core, common
            // on big.LITTLE/power-gated ARM parts) shifts which index each
            // core lands at between polls, so a positional compare would
            // silently diff one CPU's counters against another's.
            var current_each = new Gee.HashMap<string, CpuSample>();
            UtilizationReading[] readings = {};
            for (int i = 0; i < each.length; i++) {
                string label = each_labels[i];
                CpuSample? prev = _prev_cpu_each.get(label);
                double frac = prev != null ? busy_fraction(prev, each[i]) : -1.0;
                readings += new UtilizationReading(label, SensorKind.CPU, frac);
                current_each.set(label, each[i]);
            }
            _per_cpu = readings;
            _prev_cpu_each = current_each;
        }

        /**
         * Sum a /proc/stat cpu line into idle and total jiffies.
         *
         * Fields are user nice system idle iowait irq softirq steal guest
         * guest_nice. iowait counts as IDLE: the CPU is not executing during
         * it, and folding it into busy makes a machine waiting on a slow disk
         * look pegged. guest and guest_nice are excluded entirely: the kernel
         * already folds them into user and nice, so adding them again double-
         * counts guest time on any host running VMs. Remaining trailing
         * fields are summed generically so a kernel that adds another one
         * does not silently skew the total.
         */
        private CpuSample parse_cpu_fields(string[] parts) {
            var s = new CpuSample();
            for (int i = 1; i < parts.length; i++) {
                if (i == 9 || i == 10) {   // guest, guest_nice -- already in user/nice
                    continue;
                }
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
         * Done ASYNCHRONOUSLY (see kick_filesystems and probe_one_filesystem)
         * rather than inline in poll(), because query_filesystem_info() on an
         * unreachable NFS/CIFS mount blocks until the kernel's RPC timeout --
         * minutes -- and doing that on the UI's main loop froze the shell.
         * The mount-table scan itself (read /proc/mounts, filter pseudo-fs,
         * dedupe by device) is a cheap local file read and stays synchronous
         * inside kick_filesystems; only the per-mount statfs is async.
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

            // Neither the device-shape fast path nor the pseudo-filesystem
            // checks above rejected this mount, so it is a real filesystem --
            // including ones that are neither /dev/-prefixed nor colon-
            // bearing, such as a CIFS //server/share mount or a ZFS
            // pool/dataset. Falling through to false here silently dropped
            // exactly those from filesystems().
            return true;
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
