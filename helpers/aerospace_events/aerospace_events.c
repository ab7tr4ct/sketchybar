// Bridges AeroSpace events to SketchyBar.
//
// Keeps an `aerospace subscribe` connection open and, for every event line it
// prints, triggers
//   <event-name> EVENT=<type> WINDOW_ID=<id> WORKSPACE=<name>
// in sketchybar (a field the event doesn't carry is sent empty).
//
// AeroSpace sends the current focus on every connect, so the bar is resynced
// whenever this helper or AeroSpace itself restarts.
//
// Usage: aerospace_events <event-name>

#include <fcntl.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>
#include "../sketchybar.h"

#define RETRY_SECONDS 2

static pid_t g_child = 0;

static void stop_child(void) {
  if (g_child > 0) kill(g_child, SIGTERM);
}

static void on_signal(int sig) {
  (void)sig;
  stop_child();
  _exit(0);
}

// Copies the value of `key` from a flat JSON object into `out`; empty when the
// key is absent or null. Enough for AeroSpace's event lines, whose values are
// numbers and plain strings. Quote characters are dropped because the
// sketchybar message format can't carry them.
static void json_field(const char* line, const char* key, char* out, size_t size) {
  out[0] = '\0';
  char needle[64];
  snprintf(needle, sizeof(needle), "\"%s\":", key);
  const char* p = strstr(line, needle);
  if (!p) return;
  p += strlen(needle);

  bool quoted = (*p == '"');
  if (quoted) p++;
  size_t n = 0;
  for (; *p && *p != '\n' && n + 1 < size; p++) {
    if (quoted) {
      if (*p == '"') break;
      if (*p == '\\' && p[1]) p++;
    } else if (*p == ',' || *p == '}') {
      break;
    }
    if (*p == '"' || *p == '\'') continue;
    out[n++] = *p;
  }
  out[n] = '\0';
  if (!quoted && strcmp(out, "null") == 0) out[0] = '\0';
}

static void forward_event(const char* event_name, const char* line) {
  char type[64], window_id[32], workspace[256];
  json_field(line, "_event", type, sizeof(type));
  if (type[0] == '\0') return;
  json_field(line, "windowId", window_id, sizeof(window_id));
  json_field(line, "workspace", workspace, sizeof(workspace));

  char message[768];
  snprintf(message, sizeof(message),
           "--trigger '%s' EVENT='%s' WINDOW_ID='%s' WORKSPACE='%s'",
           event_name, type, window_id, workspace);
  // Exits the process when sketchybar is gone.
  sketchybar(message);
}

// Runs one `aerospace subscribe` until it ends (AeroSpace quit or restarted,
// or the CLI is missing).
static void run_subscription(const char* event_name) {
  int fds[2];
  if (pipe(fds) != 0) return;

  pid_t pid = fork();
  if (pid < 0) {
    close(fds[0]);
    close(fds[1]);
    return;
  }

  if (pid == 0) {
    // The aerospace CLI reads stdin when it isn't a TTY, so never let it
    // inherit ours.
    int devnull = open("/dev/null", O_RDWR);
    dup2(devnull, STDIN_FILENO);
    dup2(fds[1], STDOUT_FILENO);
    dup2(devnull, STDERR_FILENO);
    close(fds[0]);
    close(fds[1]);
    char* args[] = { "aerospace", "subscribe",
                     "focus-changed", "focused-workspace-changed",
                     "focused-monitor-changed", "window-detected", NULL };
    execvp(args[0], args);
    execv("/opt/homebrew/bin/aerospace", args);
    _exit(127);
  }

  g_child = pid;
  close(fds[1]);

  FILE* stream = fdopen(fds[0], "r");
  if (stream) {
    char* line = NULL;
    size_t capacity = 0;
    while (getline(&line, &capacity, stream) > 0) {
      forward_event(event_name, line);
    }
    free(line);
    fclose(stream);
  } else {
    close(fds[0]);
  }

  kill(pid, SIGTERM);
  waitpid(pid, NULL, 0);
  g_child = 0;
}

int main(int argc, char** argv) {
  if (argc < 2) {
    printf("Usage: %s \"<event-name>\"\n", argv[0]);
    return 1;
  }

  signal(SIGTERM, on_signal);
  signal(SIGINT, on_signal);
  signal(SIGHUP, on_signal);
  atexit(stop_child);

  for (;;) {
    run_subscription(argv[1]);
    // No events flow while AeroSpace is down, so check here that the bar we
    // serve still exists instead of retrying forever as an orphan.
    if (!mach_get_bs_port()) return 0;
    sleep(RETRY_SECONDS);
  }
}
