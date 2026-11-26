// Each job owns this tiny group leader. Only its parent receives the other
// endpoint of fd 0. Kernel closure on app death cleans up even without a journal.
#include <signal.h>
#include <errno.h>
#include <unistd.h>

int main(void) {
    // Refuse accidental standalone invocation or execution in another group.
    if (getpgrp() != getpid() || isatty(STDIN_FILENO)) return 64;
    signal(SIGTERM, SIG_IGN);
    signal(SIGHUP, SIG_IGN);
    signal(SIGPIPE, SIG_IGN);
    if (write(STDIN_FILENO, "R", 1) != 1) return 70;
    for (;;) {
        char command;
        ssize_t count = read(STDIN_FILENO, &command, 1);
        if (count < 0 && errno == EINTR) continue;
        if (count == 1 && command == 'T') {
            kill(0, SIGTERM);
            continue;
        }
        // kill(0, ...) addresses our own group atomically, even as workers exit.
        kill(0, SIGKILL);
        return 70;
    }
}
