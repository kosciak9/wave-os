#include <os/log.h>

int wave_os_log(const char *message) {
    os_log_t log = os_log_create("org.wave-os.wave", "lifecycle");
    if (log == NULL) {
        return 0;
    }
    os_log_with_type(log, OS_LOG_TYPE_DEFAULT, "%{public}s", message);
    os_release(log);
    return 1;
}
