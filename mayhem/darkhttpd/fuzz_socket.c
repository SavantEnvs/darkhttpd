/* Runs the real darkhttpd server loop in a background thread and feeds each fuzz input to it over a
 * loopback TCP socket. Same idea as devel/fuzz_socket.cc, but built as C so it can reach darkhttpd.c's
 * static state, and it picks a free port instead of a fixed one. */
#define main darkhttpd_main
#include "../../darkhttpd.c"
#undef main

#include <pthread.h>
#include <sched.h>
#include <sys/stat.h>
#include <arpa/inet.h>

static struct sockaddr_in addrin;

static void *server_thread(void *arg) {
  char **av = arg;
  int ac = 0;
  while (av[ac]) ac++;
  darkhttpd_main(ac, av);
  return NULL;
}

static int free_port(void) {
  struct sockaddr_in a;
  socklen_t len = sizeof(a);
  int s = socket(AF_INET, SOCK_STREAM, 0);
  if (s == -1) err(1, "socket");
  memset(&a, 0, sizeof(a));
  a.sin_family = AF_INET;
  a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  if (bind(s, (struct sockaddr *)&a, sizeof(a)) == -1) err(1, "bind");
  if (getsockname(s, (struct sockaddr *)&a, &len) == -1) err(1, "getsockname");
  close(s);
  return ntohs(a.sin_port);
}

static void write_file(const char *dir, const char *name, const char *body) {
  char path[512];
  snprintf(path, sizeof(path), "%s/%s", dir, name);
  FILE *f = fopen(path, "w");
  if (!f) err(1, "fopen %s", path);
  fputs(body, f);
  fclose(f);
}

static void init_server(void) {
  static char root[256], portstr[16];
  const char *tmp = getenv("TMPDIR");
  char sub[300];
  pthread_t thr;
  int port = free_port();

  snprintf(root, sizeof(root), "%s/darkhttpd-fuzz-XXXXXX", tmp ? tmp : "/tmp");
  if (!mkdtemp(root)) err(1, "mkdtemp");
  write_file(root, "hello.txt", "hello\n");
  write_file(root, "page.html", "<html><body>hi</body></html>\n");
  snprintf(sub, sizeof(sub), "%s/sub", root);
  if (mkdir(sub, 0755) == -1) err(1, "mkdir");
  write_file(sub, "index.html", "index\n");
  snprintf(sub, sizeof(sub), "%s/listing", root);
  if (mkdir(sub, 0755) == -1) err(1, "mkdir");
  write_file(sub, "a b.txt", "x\n");

  snprintf(portstr, sizeof(portstr), "%d", port);
  static char *av[] = {"darkhttpd", root, "--port", portstr, "--addr", "127.0.0.1",
                       "--log", "/dev/null", "--forward", "example.com", "http://www.example.com",
                       NULL};
  if (pthread_create(&thr, NULL, server_thread, av) != 0) err(1, "pthread_create");

  addrin.sin_family = AF_INET;
  addrin.sin_port = htons(port);
  addrin.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  while (!running) sched_yield();
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  static int inited = 0;
  char buf[4096];
  int fd;

  if (!inited) {
    init_server();
    inited = 1;
  }

  fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd == -1) err(1, "socket");
  if (connect(fd, (struct sockaddr *)&addrin, sizeof(addrin)) == -1) {
    close(fd);
    if (errno == EINTR) return 0;
    err(1, "connect");
  }
  if (size > 0 && send(fd, data, size, 0) != (ssize_t)size) err(1, "send");
  send(fd, "\n\n\n", 3, 0); /* terminate the request so the server answers */
  recv(fd, buf, sizeof(buf), 0);
  close(fd);
  return 0;
}
