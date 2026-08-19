using GLib;

/*
 * Fixture tests for UtilizationMonitor's parsing and delta rules.
 *
 * Every case here is a way the figure can be wrong while still looking
 * plausible on screen -- a first sample that reads as an idle machine, a
 * disk counted three times because its partitions were listed, iowait folded
 * into busy so a machine waiting on storage looks pegged. Those are invisible
 * in a screenshot, which is why they are asserted here.
 */

private string fixture_root;

private void write_file(string path, string contents) {
    string dir = Path.get_dirname(path);
    assert(DirUtils.create_with_parents(dir, 0755) == 0);
    try {
        assert(FileUtils.set_contents(path, contents));
    } catch (FileError e) {
        error("fixture write failed: %s", e.message);
    }
}

private void write_proc(string name, string contents) {
    write_file(Path.build_filename(fixture_root, "proc", name), contents);
}

/** Mark a device as a whole disk, the way /sys/block does. */
private void whole_disk(string name) {
    assert(DirUtils.create_with_parents(
        Path.build_filename(fixture_root, "sys", "block", name), 0755) == 0);
}

/** Float comparison without pulling libm in for one call. */
private bool approx(double a, double b) {
    double d = a - b;
    if (d < 0) d = -d;
    return d < 0.0001;
}

private Singularity.UtilizationMonitor fresh_monitor() {
    var m = new Singularity.UtilizationMonitor();
    m.proc_root = fixture_root;
    return m;
}

private void setup() {
    try {
        fixture_root = DirUtils.make_tmp("singularity-util-XXXXXX");
    } catch (FileError e) {
        error("tmp dir: %s", e.message);
    }
    // Minimal files so a poll() never trips over a missing one.
    write_proc("stat", "cpu 0 0 0 0 0 0 0 0 0 0\n");
    write_proc("meminfo", "MemTotal: 1000 kB\nMemAvailable: 1000 kB\n");
    write_proc("diskstats", "");
    write_proc("mounts", "");
}

/**
 * Remove the fixture tree.
 *
 * Implemented on GLib rather than by shelling out through the POSIX binding,
 * so this target needs no vala package beyond gio and gee. A --pkg the meson
 * target does not declare compiles fine by hand and then breaks `meson test`.
 */
private void remove_recursive(string path) {
    try {
        Dir dir = Dir.open(path);
        string? name;
        while ((name = dir.read_name()) != null) {
            string child = Path.build_filename(path, name);
            if (FileUtils.test(child, FileTest.IS_DIR)) {
                remove_recursive(child);
            } else {
                FileUtils.unlink(child);
            }
        }
    } catch (FileError e) {
        return;   // already gone, or never created
    }
    DirUtils.remove(path);
}

private void teardown() {
    remove_recursive(fixture_root);
}

/* ---- CPU ------------------------------------------------------------- */

/**
 * The first sample cannot produce a rate, and must say so.
 *
 * Reporting 0.0 here would render a confident "CPU 0%" for one whole interval
 * every time the panel is opened -- indistinguishable from an idle machine.
 */
private void test_cpu_first_sample_is_unknown() {
    setup();
    write_proc("stat", "cpu  100 0 100 800 0 0 0 0 0 0\n");
    var m = fresh_monitor();
    m.poll();
    assert(m.cpu_fraction == -1.0);
    teardown();
}

/** Two samples, 200 busy jiffies out of 1000, is 20%. */
private void test_cpu_delta_fraction() {
    setup();
    write_proc("stat", "cpu  100 0 100 800 0 0 0 0 0 0\n");
    var m = fresh_monitor();
    m.poll();
    // +100 user, +100 system, +800 idle => 200 busy of 1000.
    write_proc("stat", "cpu  200 0 200 1600 0 0 0 0 0 0\n");
    m.poll();
    assert(approx(m.cpu_fraction, 0.2));
    teardown();
}

/**
 * iowait is idle, not busy.
 *
 * The CPU executes nothing during iowait. Counting it as busy makes a box
 * blocked on a slow disk report 100% CPU, which sends the reader after
 * entirely the wrong problem.
 */
private void test_iowait_counts_as_idle() {
    setup();
    write_proc("stat", "cpu  0 0 0 0 0 0 0 0 0 0\n");
    var m = fresh_monitor();
    m.poll();
    // Entire delta is iowait: field 5.
    write_proc("stat", "cpu  0 0 0 0 1000 0 0 0 0 0\n");
    m.poll();
    assert(m.cpu_fraction == 0.0);
    teardown();
}

/** A counter that goes backwards (hotplug) yields unknown, not a wild value. */
private void test_cpu_counter_regression_is_unknown() {
    setup();
    write_proc("stat", "cpu  1000 0 1000 1000 0 0 0 0 0 0\n");
    var m = fresh_monitor();
    m.poll();
    write_proc("stat", "cpu  10 0 10 10 0 0 0 0 0 0\n");
    m.poll();
    assert(m.cpu_fraction == -1.0);
    teardown();
}

/** Per-core rows are labelled and separate from the aggregate. */
private void test_per_cpu_rows() {
    setup();
    write_proc("stat",
        "cpu  0 0 0 0 0 0 0 0 0 0\n" +
        "cpu0 0 0 0 0 0 0 0 0 0 0\n" +
        "cpu1 0 0 0 0 0 0 0 0 0 0\n" +
        "intr 12345\n");
    var m = fresh_monitor();
    m.poll();
    // cpu0 fully busy, cpu1 fully idle.
    write_proc("stat",
        "cpu  100 0 0 100 0 0 0 0 0 0\n" +
        "cpu0 100 0 0 0 0 0 0 0 0 0\n" +
        "cpu1 0 0 0 100 0 0 0 0 0 0\n" +
        "intr 12399\n");
    m.poll();

    var rows = m.per_cpu();
    assert(rows.length == 2);
    assert(rows[0].label == "cpu0");
    assert(rows[1].label == "cpu1");
    assert(rows[0].fraction == 1.0);
    assert(rows[1].fraction == 0.0);
    assert(rows[0].kind == Singularity.SensorKind.CPU);
    teardown();
}

/* ---- memory ---------------------------------------------------------- */

/**
 * Used memory is MemTotal - MemAvailable.
 *
 * Using MemFree instead would count reclaimable page cache as used, and a
 * healthy Linux system would sit at ~95% forever.
 */
private void test_memory_uses_available_not_free() {
    setup();
    write_proc("meminfo",
        "MemTotal:       1000 kB\n" +
        "MemFree:          50 kB\n" +      // would say 95% used
        "MemAvailable:    600 kB\n" +      // truth: 40% used
        "SwapTotal:         0 kB\n" +
        "SwapFree:          0 kB\n");
    var m = fresh_monitor();
    m.poll();
    assert(approx(m.memory_fraction, 0.4));
    assert(m.memory_total_bytes == 1000 * 1024);
    assert(m.memory_used_bytes == 400 * 1024);
    teardown();
}

/** No swap configured reads as unknown, so the caller can omit the row. */
private void test_no_swap_is_unknown_not_zero() {
    setup();
    write_proc("meminfo",
        "MemTotal:       1000 kB\nMemAvailable:    500 kB\n" +
        "SwapTotal:         0 kB\nSwapFree:          0 kB\n");
    var m = fresh_monitor();
    m.poll();
    assert(m.swap_fraction == -1.0);
    teardown();
}

private void test_swap_fraction() {
    setup();
    write_proc("meminfo",
        "MemTotal:       1000 kB\nMemAvailable:    500 kB\n" +
        "SwapTotal:      1000 kB\nSwapFree:        250 kB\n");
    var m = fresh_monitor();
    m.poll();
    assert(approx(m.swap_fraction, 0.75));
    teardown();
}

/* ---- disks ----------------------------------------------------------- */

private const string DISKSTATS =
    " 259  0 nvme0n1 100 0 200 10 50 0 100 5 0 1000 20\n" +
    " 259  1 nvme0n1p1 90 0 180 9 45 0 90 4 0 900 18\n" +
    " 259  2 nvme0n1p2 10 0 20 1 5 0 10 1 0 100 2\n" +
    "   7  0 loop0 1 0 2 0 0 0 0 0 0 5 0\n";

/**
 * Partitions and loop devices are not disks.
 *
 * A partition's busy time is its parent's counted again, so listing
 * nvme0n1p1 and p2 shows one NVMe three times; a squashfs live image carries
 * dozens of loop devices, none of which is storage the user has.
 */
private void test_partitions_and_loops_excluded() {
    setup();
    whole_disk("nvme0n1");   // only the parent is in /sys/block
    write_proc("diskstats", DISKSTATS);
    var m = fresh_monitor();
    m.poll();

    var rows = m.disks();
    assert(rows.length == 1);
    assert(rows[0].label == "nvme0n1");
    assert(rows[0].kind == Singularity.SensorKind.STORAGE);
    teardown();
}

/** Like CPU, the first disk sample has no previous to subtract from. */
private void test_disk_first_sample_is_unknown() {
    setup();
    whole_disk("nvme0n1");
    write_proc("diskstats", DISKSTATS);
    var m = fresh_monitor();
    m.poll();
    assert(m.disks()[0].fraction == -1.0);
    teardown();
}

/** A second sample produces a fraction inside [0, 1]. */
private void test_disk_busy_is_bounded() {
    setup();
    whole_disk("nvme0n1");
    write_proc("diskstats", DISKSTATS);
    var m = fresh_monitor();
    m.poll();
    Thread.usleep(20000);   // 20 ms of wall clock to divide by
    // io_ticks jumps by a wildly implausible amount; must clamp, not overflow.
    write_proc("diskstats",
        " 259  0 nvme0n1 100 0 200 10 50 0 100 5 0 999000 20\n");
    m.poll();

    double f = m.disks()[0].fraction;
    assert(f >= 0.0 && f <= 1.0);
    teardown();
}

/* ---- filesystems ----------------------------------------------------- */

/** Pseudo filesystems never appear as storage the user can fill. */
private void test_pseudo_filesystems_excluded() {
    setup();
    write_proc("mounts",
        "proc /proc proc rw 0 0\n" +
        "sysfs /sys sysfs rw 0 0\n" +
        "tmpfs /run tmpfs rw 0 0\n" +
        "cgroup2 /sys/fs/cgroup cgroup2 rw 0 0\n");
    var m = fresh_monitor();
    m.poll();
    assert(m.filesystems().length == 0);
    teardown();
}

/**
 * A real device is reported, and only once even when bind-mounted.
 *
 * The mount point used is the fixture directory itself so that the real
 * filesystem query underneath has something that exists to answer about.
 */
private void test_real_filesystem_reported_and_deduped() {
    setup();
    write_proc("mounts",
        "/dev/fake0 %s ext4 rw 0 0\n".printf(fixture_root) +
        "/dev/fake0 %s ext4 rw 0 0\n".printf(fixture_root) +
        "proc /proc proc rw 0 0\n");
    var m = fresh_monitor();
    m.poll();

    var fs = m.filesystems();
    assert(fs.length == 1);
    assert(fs[0].total_bytes > 0);
    assert(fs[0].fraction >= 0.0 && fs[0].fraction <= 1.0);
    teardown();
}

/**
 * Loop-mounted images are not storage.
 *
 * VERBATIM from cixmini's /proc/mounts on 2026-08-19, where four ISOs were
 * loop-mounted under /mnt. Each reported 100% full, because an ISO always is,
 * and each double-counted bytes already charged to the filesystem holding the
 * image file. The panel would have shown four permanently-alarming disks.
 */
private void test_loop_mounted_images_excluded() {
    setup();
    write_proc("mounts",
        "/dev/loop0 /mnt/isov9 iso9660 ro,relatime,nojoliet,check=s,map=n,blocksize=2048,iocharset=utf8 0 0\n" +
        "/dev/loop3 /mnt/isov11 iso9660 ro,relatime,nojoliet,check=s,map=n,blocksize=2048,iocharset=utf8 0 0\n" +
        "/dev/fake0 %s ext4 rw,relatime 0 0\n".printf(fixture_root));
    var m = fresh_monitor();
    m.poll();

    var fs = m.filesystems();
    assert(fs.length == 1);
    assert(fs[0].label == fixture_root);
    teardown();
}

/** A filesystem reporting no size yields unknown rather than a divide by zero. */
private void test_zero_sized_capacity_is_unknown() {
    var r = new Singularity.CapacityReading("/x", 0, 0);
    assert(r.fraction == -1.0);
}

/* ---- lifecycle -------------------------------------------------------- */

/**
 * stop() then start() must not measure a delta across the gap.
 *
 * A panel closed for an hour would otherwise report one interval computed
 * over that hour the moment it reopened.
 */
private void test_restart_discards_rate_state() {
    setup();
    write_proc("stat", "cpu  100 0 100 800 0 0 0 0 0 0\n");
    var m = fresh_monitor();
    m.poll();
    write_proc("stat", "cpu  200 0 200 1600 0 0 0 0 0 0\n");
    m.poll();
    assert(m.cpu_fraction > 0.0);      // a rate exists

    m.stop();
    m.start();                          // start() polls once itself
    assert(m.cpu_fraction == -1.0);     // and it is back to unknown
    m.stop();
    teardown();
}

public static int main(string[] args) {
    Test.init(ref args);
    Test.add_func("/utilization/cpu/first-sample-unknown", test_cpu_first_sample_is_unknown);
    Test.add_func("/utilization/cpu/delta-fraction", test_cpu_delta_fraction);
    Test.add_func("/utilization/cpu/iowait-is-idle", test_iowait_counts_as_idle);
    Test.add_func("/utilization/cpu/counter-regression", test_cpu_counter_regression_is_unknown);
    Test.add_func("/utilization/cpu/per-core-rows", test_per_cpu_rows);
    Test.add_func("/utilization/mem/available-not-free", test_memory_uses_available_not_free);
    Test.add_func("/utilization/mem/no-swap-unknown", test_no_swap_is_unknown_not_zero);
    Test.add_func("/utilization/mem/swap-fraction", test_swap_fraction);
    Test.add_func("/utilization/disk/partitions-excluded", test_partitions_and_loops_excluded);
    Test.add_func("/utilization/disk/first-sample-unknown", test_disk_first_sample_is_unknown);
    Test.add_func("/utilization/disk/busy-bounded", test_disk_busy_is_bounded);
    Test.add_func("/utilization/fs/pseudo-excluded", test_pseudo_filesystems_excluded);
    Test.add_func("/utilization/fs/real-deduped", test_real_filesystem_reported_and_deduped);
    Test.add_func("/utilization/fs/loop-images-excluded", test_loop_mounted_images_excluded);
    Test.add_func("/utilization/fs/zero-size-unknown", test_zero_sized_capacity_is_unknown);
    Test.add_func("/utilization/lifecycle/restart-discards-state", test_restart_discards_rate_state);
    return Test.run();
}
