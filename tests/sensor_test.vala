using GLib;

/*
 * Fixture tests for SensorMonitor's classification and fallback rules.
 *
 * Every case here is a shape that was observed on real hardware and got the
 * answer wrong at some point. They are written as synthetic sysfs trees because
 * that is the only way to test eight machines' worth of layouts on one.
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

/** Create /sys/class/hwmon/hwmonN with a chip name. */
private string hwmon_chip(int n, string name) {
    string dir = Path.build_filename(fixture_root, "sys", "class", "hwmon", "hwmon%d".printf(n));
    write_file(Path.build_filename(dir, "name"), name + "\n");
    return dir;
}

private void hwmon_temp(string chip_dir, int idx, int millidegrees, string? label) {
    write_file(Path.build_filename(chip_dir, "temp%d_input".printf(idx)),
               "%d\n".printf(millidegrees));
    if (label != null) {
        write_file(Path.build_filename(chip_dir, "temp%d_label".printf(idx)), label + "\n");
    }
}

private void thermal_zone(int n, string type, int millidegrees) {
    string dir = Path.build_filename(fixture_root, "sys", "class", "thermal",
                                     "thermal_zone%d".printf(n));
    write_file(Path.build_filename(dir, "type"), type + "\n");
    write_file(Path.build_filename(dir, "temp"), "%d\n".printf(millidegrees));
}

/** Add a critical trip point to an existing thermal zone. */
private void thermal_trip(int n, int idx, string trip_type, int millidegrees) {
    string dir = Path.build_filename(fixture_root, "sys", "class", "thermal",
                                     "thermal_zone%d".printf(n));
    write_file(Path.build_filename(dir, "trip_point_%d_type".printf(idx)),
               trip_type + "\n");
    write_file(Path.build_filename(dir, "trip_point_%d_temp".printf(idx)),
               "%d\n".printf(millidegrees));
}

/** Create /sys/devices/system/cpu/cpufreq/policyN. */
private void cpufreq_policy(int n, int cur_khz, int max_khz) {
    string dir = Path.build_filename(fixture_root, "sys", "devices", "system",
                                     "cpu", "cpufreq", "policy%d".printf(n));
    write_file(Path.build_filename(dir, "scaling_cur_freq"), "%d\n".printf(cur_khz));
    if (max_khz > 0) {
        write_file(Path.build_filename(dir, "cpuinfo_max_freq"), "%d\n".printf(max_khz));
    }
}

private Singularity.SensorReading? reading_named(Singularity.SensorMonitor m,
                                                 string needle) {
    foreach (Singularity.SensorReading r in m.readings()) {
        if (needle in r.label) {
            return r;
        }
    }
    return null;
}

private void remove_path(File file) {
    try {
        var type = file.query_file_type(FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
        if (type == FileType.DIRECTORY) {
            var children = file.enumerate_children(FileAttribute.STANDARD_NAME,
                                                   FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
            FileInfo? info;
            while ((info = children.next_file()) != null) {
                remove_path(file.get_child(info.get_name()));
            }
        }
        file.delete();
    } catch (GLib.Error e) {
        // best effort; the tree lives under /tmp
    }
}

private void reset_fixture() {
    if (fixture_root != null && FileUtils.test(fixture_root, FileTest.EXISTS)) {
        remove_path(File.new_for_path(fixture_root));
    }
    try {
        fixture_root = DirUtils.make_tmp("singularity-sensor-XXXXXX");
    } catch (FileError e) {
        error("cannot create fixture root: %s", e.message);
    }
}

private Singularity.SensorMonitor monitor_for_fixture() {
    var m = new Singularity.SensorMonitor();
    m.sysfs_root = fixture_root;
    m.refresh();
    return m;
}

/*
 * A NIC and a chipset sensor must never be reported as the CPU.
 *
 * MEASURED: an early version treated any unrecognised sensor as CPU and
 * displayed "enp1s0 PHY" 68 C on a Ryzen 8700G and "pch_cometlake" on a laptop.
 */
private void test_unknown_sensors_are_never_cpu() {
    reset_fixture();
    string nic = hwmon_chip(0, "enp1s0");
    hwmon_temp(nic, 1, 68000, "PHY Temperature");
    string pch = hwmon_chip(1, "pch_cometlake");
    hwmon_temp(pch, 1, 43000, null);
    string cpu = hwmon_chip(2, "k10temp");
    hwmon_temp(cpu, 1, 59000, "Tctl");

    var m = monitor_for_fixture();
    assert(m.cpu_millidegrees == 59000);
}

/*
 * With no recognised CPU sensor at all, cpu_millidegrees stays -1 rather than
 * picking the hottest thing in the box.
 */
private void test_no_cpu_sensor_reports_minus_one() {
    reset_fixture();
    string smm = hwmon_chip(0, "dell_smm");
    hwmon_temp(smm, 1, 85000, null);

    var m = monitor_for_fixture();
    assert(m.cpu_millidegrees == -1);
    assert(m.system_millidegrees == 85000);
}

/*
 * hwmon can be non-empty and still contain no CPU or GPU, in which case the
 * thermal zones must still be read.
 *
 * MEASURED on an NVIDIA IGX Thor dev kit: hwmon had Super-I/O, INA rails, the
 * NIC and the NVMe; cpu-thermal and gpu-thermal were thermal zones. A
 * hwmon-first-with-fallback design reported no CPU there.
 */
private void test_thermal_read_even_when_hwmon_nonempty() {
    reset_fixture();
    string sio = hwmon_chip(0, "f75308");
    hwmon_temp(sio, 1, 30000, null);
    thermal_zone(0, "cpu-thermal", 42000);
    thermal_zone(1, "gpu-thermal", 39000);

    var m = monitor_for_fixture();
    assert(m.cpu_millidegrees == 42000);
    assert(m.gpu_millidegrees == 39000);
}

/*
 * The same sensor spelled two ways is reported once.
 *
 * MEASURED on a Raspberry Pi 5: hwmon "cpu_thermal", thermal zone "cpu-thermal".
 */
private void test_duplicate_sensor_listed_once() {
    reset_fixture();
    string chip = hwmon_chip(0, "cpu_thermal");
    hwmon_temp(chip, 1, 53000, null);
    thermal_zone(0, "cpu-thermal", 53000);

    var m = monitor_for_fixture();
    int cpu_readings = 0;
    foreach (var r in m.readings()) {
        if (r.kind == Singularity.SensorKind.CPU) cpu_readings++;
    }
    assert(cpu_readings == 1);
}

/*
 * A GPU zone whose name starts with "gpu" must not be mistaken for a CPU.
 *
 * MEASURED on a Snapdragon SC8280XP: 55 zones, including gpuss_0_thermal for the
 * Adreno alongside cpu0_0_thermal.
 */
private void test_gpuss_is_gpu_not_cpu() {
    reset_fixture();
    thermal_zone(0, "cpu5_1_thermal", 42000);
    thermal_zone(1, "gpuss_3_thermal", 47000);

    var m = monitor_for_fixture();
    assert(m.cpu_millidegrees == 42000);
    assert(m.gpu_millidegrees == 47000);
}

/*
 * A cpufreq directory that exists but yields nothing must still fall back to
 * /proc/cpuinfo. The fallback used to live in catch(FileError), so it only ran
 * when the directory was absent -- an empty one left cpu_khz at -1.
 */
private void test_cpufreq_empty_dir_falls_back_to_cpuinfo() {
    reset_fixture();
    assert(DirUtils.create_with_parents(
        Path.build_filename(fixture_root, "sys", "devices", "system", "cpu", "cpufreq"),
        0755) == 0);
    write_file(Path.build_filename(fixture_root, "proc", "cpuinfo"),
               "processor\t: 0\ncpu MHz\t\t: 2000.000\n");

    var m = monitor_for_fixture();
    assert(m.cpu_khz == 2000000);
}

/*
 * available means "something readable", not "a temperature was readable". A VM
 * or restricted-hwmon setup can expose only a fan.
 */
private void test_available_with_fan_but_no_temperature() {
    reset_fixture();
    string chip = hwmon_chip(0, "some_fan_controller");
    write_file(Path.build_filename(chip, "fan1_input"), "1200\n");

    var m = monitor_for_fixture();
    assert(m.cpu_millidegrees == -1);
    assert(m.available);
}


/*
 * A sentinel must not become the hottest sensor on the machine.
 *
 * MEASURED on a fleet host: a hwmon node reported 65261850 -- 65261 C. With no
 * ceiling it wins every "hottest" comparison, pins the summary chip to itself
 * and paints the panel permanently critical. -274000 is the same class of
 * value from the other end, below absolute zero.
 */
private void test_sentinel_temperatures_are_rejected() {
    reset_fixture();
    string junk = hwmon_chip(0, "k10temp");
    hwmon_temp(junk, 1, 65261850, "Tctl");
    hwmon_temp(junk, 2, -274000, "Tdie");
    hwmon_temp(junk, 3, 54000, "Tccd1");

    var m = monitor_for_fixture();
    // Only the believable one survives, so it is also the hottest CPU.
    assert(m.cpu_millidegrees == 54000);
    assert(reading_named(m, "Tctl") == null);
    assert(reading_named(m, "Tdie") == null);
}

/*
 * tempN_crit, when the driver publishes one, is the limit.
 */
private void test_hwmon_crit_becomes_the_limit() {
    reset_fixture();
    string nvme = hwmon_chip(0, "nvme");
    hwmon_temp(nvme, 1, 48000, "Composite");
    write_file(Path.build_filename(nvme, "temp1_crit"), "84850\n");

    var m = monitor_for_fixture();
    var r = reading_named(m, "Composite");
    assert(r != null);
    assert(r.limit_millidegrees == 84850);
    // 36 C of margin: unremarkable, despite being a drive.
    assert(r.severity == Singularity.Severity.NORMAL);
}

/*
 * tempN_crit is preferred over tempN_max.
 *
 * _max is frequently a soft target a chip sits at under full load; treating it
 * as critical reports a merely busy CPU as overheating.
 */
private void test_crit_preferred_over_max() {
    reset_fixture();
    string cpu = hwmon_chip(0, "coretemp");
    hwmon_temp(cpu, 1, 82000, "Package id 0");
    write_file(Path.build_filename(cpu, "temp1_max"), "84000\n");
    write_file(Path.build_filename(cpu, "temp1_crit"), "100000\n");

    var m = monitor_for_fixture();
    var r = reading_named(m, "Package id 0");
    assert(r != null);
    assert(r.limit_millidegrees == 100000);
    // 18 C of margin against the hard limit is warm. Had _max been taken as
    // the limit the margin would have been 2 C and this busy-but-healthy CPU
    // would have been reported as HOT -- which is the whole point of the
    // preference.
    assert(r.severity == Singularity.Severity.WARM);
}

/*
 * THE CASE THAT MAKES FALLBACKS NECESSARY.
 *
 * MEASURED across the fleet: k10temp (Ryzen), scmi (CIX Sky1) and cpu_thermal
 * (Pi, most Arm SoCs) publish tempN_input with no tempN_crit and no critical
 * trip point whatsoever. Without a fallback the CPU -- the one sensor anybody
 * watches -- would be uncoloured on every Arm and AMD machine we ship.
 */
private void test_driver_without_crit_still_gets_a_limit() {
    reset_fixture();
    string cpu = hwmon_chip(0, "scmi_sensors");
    hwmon_temp(cpu, 1, 91000, "CPU_B0");

    var m = monitor_for_fixture();
    var r = reading_named(m, "CPU_B0");
    assert(r != null);
    assert(r.limit_millidegrees == 100000);
    // 9 C of margin.
    assert(r.severity == Singularity.Severity.HOT);
}

/*
 * A thermal zone with a critical trip point uses it, and the LOWEST one when
 * several are published -- the first trip reached is the one that matters.
 */
private void test_thermal_uses_lowest_critical_trip() {
    reset_fixture();
    thermal_zone(0, "cpu-thermal", 70000);
    thermal_trip(0, 0, "passive", 85000);
    thermal_trip(0, 1, "critical", 105000);
    thermal_trip(0, 2, "critical", 95000);

    var m = monitor_for_fixture();
    var r = reading_named(m, "cpu-thermal");
    assert(r != null);
    assert(r.limit_millidegrees == 95000);
    assert(r.margin_millidegrees == 25000);
    assert(r.severity == Singularity.Severity.NORMAL);
}

/*
 * The severity bands, at their exact boundaries. Margin-based, so a device
 * with a low limit is not called warm at its idle temperature.
 */
private void test_severity_bands() {
    reset_fixture();
    thermal_zone(0, "cpu-thermal", 70000);
    thermal_trip(0, 0, "critical", 95000);   // 25 C margin -> NORMAL
    thermal_zone(1, "gpu-thermal", 71000);
    thermal_trip(1, 0, "critical", 95000);   // 24 C margin -> WARM
    thermal_zone(2, "ddr-thermal", 84000);
    thermal_trip(2, 0, "critical", 95000);   // 11 C margin -> HOT
    thermal_zone(3, "npu-thermal", 96000);
    thermal_trip(3, 0, "critical", 95000);   // over -> CRITICAL

    var m = monitor_for_fixture();
    assert(reading_named(m, "cpu-thermal").severity == Singularity.Severity.NORMAL);
    assert(reading_named(m, "gpu-thermal").severity == Singularity.Severity.WARM);
    assert(reading_named(m, "ddr-thermal").severity == Singularity.Severity.HOT);
    assert(reading_named(m, "npu-thermal").severity == Singularity.Severity.CRITICAL);
}

/*
 * EACH CLOCK CARRIES ITS OWN POLICY MAXIMUM.
 *
 * MEASURED on CIX Sky1: five cpufreq policies with five different maxima. A
 * single machine-wide maximum would normalise the little cores against a big
 * core ceiling and paint them permanently idle -- here the little core is at
 * its own limit while the big core is barely off idle.
 */
private void test_clocks_normalise_per_policy() {
    reset_fixture();
    cpufreq_policy(0, 1800000, 1800000);   // little, flat out
    cpufreq_policy(4, 1900000, 2600000);   // big, part way

    var m = monitor_for_fixture();
    var clocks = m.clocks();
    assert(clocks.length == 2);
    // Sorted highest kHz first, and the maximum travelled with the reading
    // rather than being paired to the wrong policy.
    assert(clocks[0].khz == 1900000 && clocks[0].max_khz == 2600000);
    assert(clocks[1].khz == 1800000 && clocks[1].max_khz == 1800000);
    assert(clocks[1].fraction == 1.0);
    assert(clocks[0].fraction < 0.75);
    // The kHz-only view stays in the same order for existing callers.
    assert(m.clocks_khz()[0] == 1900000);
}

/*
 * /proc/cpuinfo publishes a current MHz and no maximum, so those readings must
 * report their fraction as unknown rather than inventing a denominator.
 */
private void test_cpuinfo_clocks_have_no_fraction() {
    reset_fixture();
    write_file(Path.build_filename(fixture_root, "proc", "cpuinfo"),
               "processor\t: 0\ncpu MHz\t\t: 2400.000\n");

    var m = monitor_for_fixture();
    var clocks = m.clocks();
    assert(clocks.length == 1);
    assert(clocks[0].khz == 2400000);
    assert(clocks[0].max_khz == 0);
    assert(clocks[0].fraction == -1.0);
}


/*
 * THE SHAPE OF THE SoC THIS DISTRIBUTION TARGETS.
 *
 * MEASURED on CIX Sky1: ONE hwmon chip named scmi_sensors carries all 22
 * sensors, and CPU, GPU, NPU, VPU, DDR and PCB are told apart only by their
 * labels. The chip name matches nothing in either allow-list, so before the
 * labels were consulted this board reported cpu=-1 and gpu=-1 -- no CPU and no
 * GPU temperature at all on the hardware the product exists for.
 */
private void test_scmi_labels_identify_cpu_and_gpu() {
    reset_fixture();
    string scmi = hwmon_chip(0, "scmi_sensors");
    hwmon_temp(scmi, 1, 61000, "CPU_B0");
    hwmon_temp(scmi, 2, 58000, "CPU_M1");
    hwmon_temp(scmi, 3, 55000, "GPU_AVE");
    hwmon_temp(scmi, 4, 71000, "DDR_top");
    hwmon_temp(scmi, 5, 49000, "NPU");
    hwmon_temp(scmi, 6, 47000, "PCB_AMB");

    var m = monitor_for_fixture();
    assert(m.cpu_millidegrees == 61000);
    assert(m.gpu_millidegrees == 55000);
    // DDR is the hottest thing on the board and must NOT become the CPU.
    // It is now named MEMORY rather than dumped in SYSTEM, but the property
    // this test exists for is unchanged: it is not the CPU and not the GPU.
    assert(reading_named(m, "DDR_top").kind == Singularity.SensorKind.MEMORY);
    assert(reading_named(m, "NPU").kind == Singularity.SensorKind.NPU);
    assert(m.cpu_millidegrees != 71000);
    assert(m.gpu_millidegrees != 71000);
}

/*
 * A VRM label contains "cpu" but is not the die. It runs hotter than the part
 * it feeds, so with hottest-wins it would be reported as the CPU temperature
 * and overstate it.
 */
private void test_vrm_labels_are_not_the_die() {
    reset_fixture();
    string sio = hwmon_chip(0, "nct6798");
    hwmon_temp(sio, 1, 88000, "CPU VRM");
    string cpu = hwmon_chip(1, "k10temp");
    hwmon_temp(cpu, 1, 62000, "Tctl");

    var m = monitor_for_fixture();
    assert(m.cpu_millidegrees == 62000);
    assert(reading_named(m, "VRM").kind == Singularity.SensorKind.SYSTEM);
}

/*
 * A thermal zone that duplicates an hwmon chip by name is dropped -- but its
 * limit is not, when hwmon published none.
 *
 * MEASURED on CIX Sky1: hwmon exposes four sensors named acpitz with no
 * tempN_crit, and four identically named thermal zones each carrying a 98 C
 * critical trip. Dropping the zones outright discarded the only real limit on
 * the machine. All four must end up on it, not just the first: a first-match
 * upgrade left three of them on the fallback, so one sensor was drawn against
 * two different limits.
 */
private void test_thermal_limit_rescued_from_dropped_duplicate() {
    reset_fixture();
    string acpi = hwmon_chip(0, "acpitz");
    hwmon_temp(acpi, 1, 44000, null);
    hwmon_temp(acpi, 2, 43000, null);
    thermal_zone(0, "acpitz", 44000);
    thermal_trip(0, 0, "critical", 98000);
    thermal_zone(1, "acpitz", 43000);
    thermal_trip(1, 0, "critical", 98000);

    var m = monitor_for_fixture();
    int seen = 0;
    foreach (Singularity.SensorReading r in m.readings()) {
        if (r.label != "acpitz") {
            continue;
        }
        seen++;
        assert(r.limit_is_reported);
        assert(r.limit_millidegrees == 98000);
    }
    // Still two sensors, not four: the zones were merged, not appended.
    assert(seen == 2);
}


/*
 * heat_fraction spans AMBIENT to the limit, not 0 C to the limit.
 *
 * MEASURED on O6N: the CPU at 49 C against a 100 C limit and the NVMe at
 * 67.8 C against 84.85 C. From ambient those separate clearly (0.36 vs 0.73)
 * and the drive is obviously the one to look at; measured from 0 C they would
 * be 0.49 and 0.80, close enough that a glance at two bars tells you little.
 */
private void test_heat_fraction_spans_from_ambient() {
    reset_fixture();
    thermal_zone(0, "cpu-thermal", 49000);
    thermal_trip(0, 0, "critical", 100000);
    string nvme = hwmon_chip(0, "nvme");
    hwmon_temp(nvme, 1, 67800, "Composite");
    write_file(Path.build_filename(nvme, "temp1_crit"), "84850\n");

    var m = monitor_for_fixture();
    double cpu = reading_named(m, "cpu-thermal").heat_fraction;
    double drive = reading_named(m, "Composite").heat_fraction;
    // (49-20)/(100-20) = 0.3625 ; (67.8-20)/(84.85-20) = 0.7370
    assert(cpu > 0.35 && cpu < 0.38);
    assert(drive > 0.72 && drive < 0.75);
    // The whole point: the drive must read visibly hotter than the CPU.
    assert(drive - cpu > 0.3);
}

/*
 * Clamped at both ends -- a sensor below ambient must not draw a negative bar,
 * and one past its limit must not overflow it.
 */
private void test_heat_fraction_is_clamped() {
    reset_fixture();
    thermal_zone(0, "cold-thermal", 5000);
    thermal_trip(0, 0, "critical", 90000);
    thermal_zone(1, "hot-thermal", 99000);
    thermal_trip(1, 0, "critical", 90000);

    var m = monitor_for_fixture();
    assert(reading_named(m, "cold-thermal").heat_fraction == 0.0);
    assert(reading_named(m, "hot-thermal").heat_fraction == 1.0);
}


/*
 * THE GROUPING THE PANEL ACTUALLY HAS TO RENDER.
 *
 * Every label here is one Sky1 reports through scmi_sensors, plus the NVMe and
 * NIC chips that sit alongside. Before the kinds were widened, all of these
 * except the CPU and GPU entries landed in SYSTEM -- 17 of 25 readings in one
 * capped list.
 */
private void test_soc_sensors_group_by_component() {
    reset_fixture();
    string scmi = hwmon_chip(0, "scmi_sensors");
    hwmon_temp(scmi, 1,  61000, "CPU_B0");
    hwmon_temp(scmi, 2,  55000, "GPU_AVE");
    hwmon_temp(scmi, 3,  49000, "NPU");
    hwmon_temp(scmi, 4,  47000, "VPU");
    hwmon_temp(scmi, 5,  71000, "DDR_top");
    hwmon_temp(scmi, 6,  46000, "PCB_AMB");
    hwmon_temp(scmi, 7,  48000, "SOC_TRC");
    string nvme = hwmon_chip(1, "nvme");
    hwmon_temp(nvme, 1,  67000, "Composite");
    string nic = hwmon_chip(2, "r8169_0_100:00");
    hwmon_temp(nic, 1,   48000, null);

    var m = monitor_for_fixture();
    assert(reading_named(m, "CPU_B0").kind    == Singularity.SensorKind.CPU);
    assert(reading_named(m, "GPU_AVE").kind   == Singularity.SensorKind.GPU);
    assert(reading_named(m, "NPU").kind       == Singularity.SensorKind.NPU);
    assert(reading_named(m, "VPU").kind       == Singularity.SensorKind.VPU);
    assert(reading_named(m, "DDR_top").kind   == Singularity.SensorKind.MEMORY);
    assert(reading_named(m, "PCB_AMB").kind   == Singularity.SensorKind.BOARD);
    assert(reading_named(m, "SOC_TRC").kind   == Singularity.SensorKind.BOARD);
    assert(reading_named(m, "Composite").kind == Singularity.SensorKind.STORAGE);
    assert(reading_named(m, "r8169").kind     == Singularity.SensorKind.NETWORK);
    // Nothing may fall through to SYSTEM on this board any more.
    foreach (Singularity.SensorReading r in m.readings()) {
        assert(r.kind != Singularity.SensorKind.SYSTEM);
    }
}

/*
 * "VPU" must not be read as a GPU, and the NPU must not be read as either.
 * Both would be swallowed by a broader match if the order were wrong.
 */
private void test_vpu_and_npu_are_not_the_gpu() {
    reset_fixture();
    string scmi = hwmon_chip(0, "scmi_sensors");
    hwmon_temp(scmi, 1, 90000, "VPU");
    hwmon_temp(scmi, 2, 91000, "NPU");
    hwmon_temp(scmi, 3, 40000, "GPU_AVE");

    var m = monitor_for_fixture();
    assert(reading_named(m, "VPU").kind == Singularity.SensorKind.VPU);
    assert(reading_named(m, "NPU").kind == Singularity.SensorKind.NPU);
    // The GPU figure must be the GPU, not the much hotter VPU next to it.
    assert(m.gpu_millidegrees == 40000);
}

public int main(string[] args) {
    Test.init(ref args);
    Test.add_func("/sensor/unknown-never-cpu", test_unknown_sensors_are_never_cpu);
    Test.add_func("/sensor/no-cpu-is-minus-one", test_no_cpu_sensor_reports_minus_one);
    Test.add_func("/sensor/thermal-when-hwmon-nonempty", test_thermal_read_even_when_hwmon_nonempty);
    Test.add_func("/sensor/duplicate-listed-once", test_duplicate_sensor_listed_once);
    Test.add_func("/sensor/gpuss-is-gpu", test_gpuss_is_gpu_not_cpu);
    Test.add_func("/sensor/cpufreq-empty-falls-back", test_cpufreq_empty_dir_falls_back_to_cpuinfo);
    Test.add_func("/sensor/available-with-fan-only", test_available_with_fan_but_no_temperature);
    Test.add_func("/sensor/sentinels-rejected", test_sentinel_temperatures_are_rejected);
    Test.add_func("/sensor/hwmon-crit-is-limit", test_hwmon_crit_becomes_the_limit);
    Test.add_func("/sensor/crit-beats-max", test_crit_preferred_over_max);
    Test.add_func("/sensor/no-crit-still-limited", test_driver_without_crit_still_gets_a_limit);
    Test.add_func("/sensor/lowest-critical-trip", test_thermal_uses_lowest_critical_trip);
    Test.add_func("/sensor/severity-bands", test_severity_bands);
    Test.add_func("/sensor/clocks-per-policy", test_clocks_normalise_per_policy);
    Test.add_func("/sensor/cpuinfo-no-fraction", test_cpuinfo_clocks_have_no_fraction);
    Test.add_func("/sensor/scmi-labels-classify", test_scmi_labels_identify_cpu_and_gpu);
    Test.add_func("/sensor/vrm-is-not-the-die", test_vrm_labels_are_not_the_die);
    Test.add_func("/sensor/limit-rescued-from-duplicate", test_thermal_limit_rescued_from_dropped_duplicate);
    Test.add_func("/sensor/heat-fraction-from-ambient", test_heat_fraction_spans_from_ambient);
    Test.add_func("/sensor/heat-fraction-clamped", test_heat_fraction_is_clamped);
    Test.add_func("/sensor/soc-groups-by-component", test_soc_sensors_group_by_component);
    Test.add_func("/sensor/vpu-npu-not-gpu", test_vpu_and_npu_are_not_the_gpu);
    int rc = Test.run();
    if (fixture_root != null && FileUtils.test(fixture_root, FileTest.EXISTS)) {
        remove_path(File.new_for_path(fixture_root));
    }
    return rc;
}
