#ifndef HUB_PROCESS_SUPPORT_H
#define HUB_PROCESS_SUPPORT_H
#include <stdint.h>
#include <sys/types.h>

typedef struct {
    pid_t pid, group;
    int control, input, output, error_output;
} hub_job;

typedef struct {
    uint64_t seconds, microseconds;
    uint32_t uid;
    pid_t group;
} hub_process_stamp;

// The worker returns suspended. Keep the guard unreaped until the group is finished.
int hub_spawn(hub_job *job, const char *guard, const char *executable, char *const argv[],
              const char *cwd, char *const envp[], int startup_ms);
int hub_resume(hub_job *job);
int hub_term(hub_job *job);
void hub_kill_group(hub_job *job);
void hub_dispose(hub_job *job);
// Returns 1 on exit, 0 if running, or negative errno.
int hub_check_exit(hub_job *job, int *exit_code, int *signal);
int hub_stamp(pid_t pid, hub_process_stamp *stamp, char *path, int path_size);
int hub_boot_session(char *destination, size_t size);
#endif
