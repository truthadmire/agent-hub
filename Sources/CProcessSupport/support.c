#include "CProcessSupport.h"
#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <string.h>
#include <sys/proc.h>
#include <sys/socket.h>
#include <sys/sysctl.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static void close_fd(int *fd) {
    if (*fd >= 0) close(*fd);
    *fd = -1;
}

static void reap(pid_t *pid) {
    if (*pid > 0) {
        while (waitpid(*pid, NULL, 0) < 0 && errno == EINTR) {}
    }
    *pid = -1;
}

static int make_pair(int pair[2], int socket_pair) {
    if (socket_pair ? socketpair(AF_UNIX, SOCK_STREAM, 0, pair) : pipe(pair)) return errno;
    // Handle host processes which started with a closed standard descriptor.
    for (int i = 0; i < 2; i++) {
        if (pair[i] < 3) {
            int replacement = fcntl(pair[i], F_DUPFD_CLOEXEC, 3);
            if (replacement < 0) return errno;
            close(pair[i]);
            pair[i] = replacement;
        }
        if (fcntl(pair[i], F_SETFD, FD_CLOEXEC) < 0) return errno;
    }
    if (socket_pair) {
        int yes = 1;
        if (setsockopt(pair[0], SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes))) return errno;
    }
    return 0;
}

static int spawn_program(pid_t *pid, pid_t group, int suspended,
                         const char *exe, char *const argv[], char *const envp[],
                         const char *cwd, const int standard[3]) {
    posix_spawnattr_t attr;
    posix_spawn_file_actions_t actions;
    int error = posix_spawnattr_init(&attr);
    if (error) return error;
    error = posix_spawn_file_actions_init(&actions);
    if (error) {
        posix_spawnattr_destroy(&attr);
        return error;
    }
    short flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT |
                  POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF;
    if (suspended) flags |= POSIX_SPAWN_START_SUSPENDED;
    sigset_t empty, defaults;
    sigemptyset(&empty);
    sigemptyset(&defaults);
    const int signals[] = { SIGPIPE, SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGCHLD };
    for (size_t i = 0; i < sizeof(signals)/sizeof(signals[0]); i++) sigaddset(&defaults, signals[i]);
    error = posix_spawnattr_setflags(&attr, flags);
    if (!error) error = posix_spawnattr_setpgroup(&attr, group);
    if (!error) error = posix_spawnattr_setsigmask(&attr, &empty);
    if (!error) error = posix_spawnattr_setsigdefault(&attr, &defaults);
    if (!error && cwd) {
        // addchdir without the suffix first shipped in macOS 26.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        error = posix_spawn_file_actions_addchdir_np(&actions, cwd);
#pragma clang diagnostic pop
    }
    for (int i = 0; !error && i < 3; i++) {
        if (standard[i] >= 0) error = posix_spawn_file_actions_adddup2(&actions, standard[i], i);
        else error = posix_spawn_file_actions_addopen(&actions, i, "/dev/null", O_RDWR, 0);
    }
    if (!error) {
        // POSIX leaves the output PID unspecified on failure.
        pid_t child = -1;
        error = posix_spawn(&child, exe, &actions, &attr, argv, envp);
        if (!error) *pid = child;
    }
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attr);
    return error;
}

static int wait_ready(int control, int timeout_ms) {
    uint64_t end = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) + (uint64_t)timeout_ms * 1000000;
    for (;;) {
        uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        if (now >= end) return ETIMEDOUT;
        struct pollfd fd = { control, POLLIN, 0 };
        int count = poll(&fd, 1, (int)((end - now + 999999) / 1000000));
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) return errno;
        if (count == 0) return ETIMEDOUT;
        char byte;
        if (read(control, &byte, 1) != 1 || byte != 'R') return EIO;
        return 0;
    }
}

int hub_spawn(hub_job *job, const char *guard, const char *exe, char *const argv[],
              const char *cwd, char *const envp[], int startup_ms) {
    *job = (hub_job){ -1, -1, -1, -1, -1, -1 };
    int pair[4][2] = { {-1,-1}, {-1,-1}, {-1,-1}, {-1,-1} };
    int error = 0;
    for (int i = 0; i < 4 && !error; i++) error = make_pair(pair[i], i <= 1);
    if (!error) {
        int io[] = { pair[0][1], -1, -1 };
        char *guard_argv[] = { (char *)guard, NULL };
        char *guard_env[] = { NULL };
        error = spawn_program(&job->group, 0, 0, guard, guard_argv, guard_env, NULL, io);
    }
    close_fd(&pair[0][1]);
    if (!error) error = wait_ready(pair[0][0], startup_ms);
    if (!error) {
        int io[] = { pair[1][1], pair[2][1], pair[3][1] };
        error = spawn_program(&job->pid, job->group, 1, exe, argv, envp, cwd, io);
    }
    int *fds[] = { &job->control, &job->input, &job->output, &job->error_output };
    for (int i = 0; i < 4; i++) {
        close_fd(&pair[i][1]);
        *fds[i] = pair[i][0];
        if (i > 0 && !error && fcntl(pair[i][0], F_SETFL, O_NONBLOCK) < 0) error = errno;
    }
    if (error) hub_dispose(job);
    return error;
}

int hub_resume(hub_job *job) {
    return kill(job->pid, SIGCONT) == 0 ? 0 : errno;
}

// All waits for these children belong to this job on its serial worker. Checking
// waitability also fails closed if another subsystem installed an auto-reaper.
static int signal_owned(pid_t child, int target_group, int signal) {
    if (child <= 0) return ESRCH;
    siginfo_t info = {0};
    int rc;
    do { rc = waitid(P_PID, (id_t)child, &info, WEXITED | WNOHANG | WNOWAIT); }
    while (rc < 0 && errno == EINTR);
    if (rc < 0) return errno;
    return kill(target_group ? -child : child, signal) == 0 ? 0 : errno;
}

int hub_term(hub_job *job) {
    char command = 'T';
    ssize_t written;
    do { written = write(job->control, &command, 1); } while (written < 0 && errno == EINTR);
    int error = written == 1 ? 0 : errno;
    if (job->pid > 0 && getpgid(job->pid) != job->group) signal_owned(job->pid, 0, SIGTERM);
    return error;
}

void hub_kill_group(hub_job *job) {
    close_fd(&job->control);
    // Guard is our exclusive, unreaped child. Its numeric PID cannot be recycled.
    // This also handles a guard stopped by the job, unable to read the EOF.
    signal_owned(job->group, 1, SIGKILL);
    // A direct child can create its own session. Its unreaped PID remains ours
    // even after leaving the group, so a run deadline still terminates that child.
    signal_owned(job->pid, 0, SIGKILL);
    reap(&job->group);
}

void hub_dispose(hub_job *job) {
    hub_kill_group(job);
    close_fd(&job->control);
    close_fd(&job->input);
    close_fd(&job->output);
    close_fd(&job->error_output);
    reap(&job->pid);
}

int hub_check_exit(hub_job *job, int *exit_code, int *sig) {
    int status = 0;
    pid_t result = waitpid(job->pid, &status, WNOHANG);
    if (result < 0) return errno == EINTR ? 0 : -errno;
    if (result == 0) return 0;
    job->pid = -1;
    *exit_code = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
    *sig = WIFSIGNALED(status) ? WTERMSIG(status) : -1;
    return 1;
}

int hub_stamp(pid_t pid, hub_process_stamp *stamp, char *path, int path_size) {
    struct proc_bsdinfo bsd;
    int count = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, sizeof(bsd));
    if (count != sizeof(bsd)) return errno ? errno : EACCES;
    if (bsd.pbi_status == SZOMB) return ESRCH;
    *stamp = (hub_process_stamp){ bsd.pbi_start_tvsec, bsd.pbi_start_tvusec, bsd.pbi_uid, (pid_t)bsd.pbi_pgid };
    if (proc_pidpath(pid, path, (uint32_t)path_size) <= 0) return errno ? errno : EACCES;
    return 0;
}

int hub_boot_session(char *destination, size_t size) {
    return sysctlbyname("kern.bootsessionuuid", destination, &size, NULL, 0) == 0 ? 0 : errno;
}
