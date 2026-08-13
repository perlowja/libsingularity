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

public int main(string[] args) {
    Test.init(ref args);
    Test.add_func("/sensor/unknown-never-cpu", test_unknown_sensors_are_never_cpu);
    Test.add_func("/sensor/no-cpu-is-minus-one", test_no_cpu_sensor_reports_minus_one);
    Test.add_func("/sensor/thermal-when-hwmon-nonempty", test_thermal_read_even_when_hwmon_nonempty);
    Test.add_func("/sensor/duplicate-listed-once", test_duplicate_sensor_listed_once);
    Test.add_func("/sensor/gpuss-is-gpu", test_gpuss_is_gpu_not_cpu);
    Test.add_func("/sensor/cpufreq-empty-falls-back", test_cpufreq_empty_dir_falls_back_to_cpuinfo);
    Test.add_func("/sensor/available-with-fan-only", test_available_with_fan_but_no_temperature);
    int rc = Test.run();
    if (fixture_root != null && FileUtils.test(fixture_root, FileTest.EXISTS)) {
        remove_path(File.new_for_path(fixture_root));
    }
    return rc;
}
