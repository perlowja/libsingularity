using GLib;

namespace Singularity {

    /**
     * Runs an external "hack" binary (a fullscreen GL/GLES demo, e.g. a
     * screensaver) as a long-lived subprocess. Unlike WallpaperHelperProvider
     * (request/response, waits for output), a hack runs until stop() is
     * called or an optional safety ceiling elapses -- it owns its own
     * surface and returns no output the caller reads.
     */
    public class HackRunner : Object {
        private Subprocess? process = null;
        private uint safety_timer = 0;

        /** Emitted when the process exits, for any reason. */
        public signal void stopped(bool crashed);

        public bool running { get { return process != null; } }

        /** Spawns binary_path with no arguments. max_runtime_sec = 0 means no ceiling. */
        public bool start(string binary_path, uint max_runtime_sec = 0) {
            if (running) return false;
            try {
                var launcher = new SubprocessLauncher(SubprocessFlags.NONE);
                process = launcher.spawnv({binary_path});
            } catch (Error e) {
                warning("HackRunner: failed to start %s: %s", binary_path, e.message);
                return false;
            }
            watch_process.begin(process);
            if (max_runtime_sec > 0) {
                safety_timer = Timeout.add_seconds(max_runtime_sec, () => {
                    safety_timer = 0;
                    stop();
                    return Source.REMOVE;
                });
            }
            return true;
        }

        /** Cooperative shutdown -- SIGTERM, the hack handles this gracefully. */
        public void stop() {
            if (process == null) return;
            process.send_signal(15);
        }

        private async void watch_process(Subprocess proc) {
            bool ok = false;
            try {
                ok = yield proc.wait_async(null);
                ok = ok && proc.get_successful();
            } catch (Error e) {
                ok = false;
            }
            if (safety_timer != 0) {
                Source.remove(safety_timer);
                safety_timer = 0;
            }
            process = null;
            stopped(!ok);
        }
    }
}
