/* SPDX-License-Identifier: GPL-3.0-or-later */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#ifndef GUIX
#error GUIX must name the Guix executable
#endif
#ifndef PROVIDER
#error PROVIDER must name the provider source tree
#endif

static void die(const char *message) {
  fprintf(stderr, "guix-rust-toolchain: %s: %s\n", message, strerror(errno));
  exit(1);
}

static void fail(const char *message) {
  fprintf(stderr, "guix-rust-toolchain: %s\n", message);
  exit(1);
}

static void *allocate(size_t size) {
  void *result = malloc(size ? size : 1);
  if (!result) die("out of memory");
  return result;
}

static char *join(const char *left, const char *right) {
  size_t length = strlen(left) + strlen(right) + 2;
  char *result = allocate(length);
  snprintf(result, length, "%s/%s", left, right);
  return result;
}

static void mkdir_if_missing(const char *path) {
  if (mkdir(path, 0700) && errno != EEXIST) die("cannot create cache directory");
}

static void mkdir_hierarchy(const char *path) {
  char *copy = strdup(path);
  if (!copy) die("out of memory");
  for (char *slash = copy + 1; *slash; slash++) {
    if (*slash != '/') continue;
    *slash = 0;
    mkdir_if_missing(copy);
    *slash = '/';
  }
  mkdir_if_missing(copy);
  free(copy);
}

static char *read_file(const char *path, size_t *length) {
  int fd = open(path, O_RDONLY);
  if (fd < 0) die("cannot read selected toolchain file");
  struct stat status;
  if (fstat(fd, &status)) die("cannot stat selected toolchain file");
  if (status.st_size < 0 || (uintmax_t)status.st_size > SIZE_MAX - 1)
    fail("selected toolchain file is too large");
  char *data = allocate((size_t)status.st_size + 1);
  size_t used = 0;
  while (used < (size_t)status.st_size) {
    ssize_t count = read(fd, data + used, (size_t)status.st_size - used);
    if (count < 0) die("cannot read selected toolchain file");
    if (!count) break;
    used += (size_t)count;
  }
  close(fd);
  data[used] = 0;
  *length = used;
  return data;
}

static int regular_file(const char *path) {
  struct stat status;
  return stat(path, &status) == 0 && S_ISREG(status.st_mode);
}

static char *find_config(void) {
  char directory[PATH_MAX];
  if (!getcwd(directory, sizeof directory)) die("cannot determine current directory");
  for (;;) {
    char *legacy = join(directory, "rust-toolchain");
    char *toml = join(directory, "rust-toolchain.toml");
    if (regular_file(legacy)) { free(toml); return legacy; }
    free(legacy);
    if (regular_file(toml)) return toml;
    free(toml);
    char *slash = strrchr(directory, '/');
    if (!slash) break;
    if (slash == directory) {
      if (!directory[1]) break;
      directory[1] = 0;
    } else {
      *slash = 0;
    }
  }
  return NULL;
}

static uint64_t hash_bytes(const void *bytes, size_t length, uint64_t hash) {
  const unsigned char *cursor = bytes;
  for (size_t index = 0; index < length; index++) {
    hash ^= cursor[index];
    hash *= UINT64_C(1099511628211);
  }
  return hash;
}

static char *scheme_string(const char *text) {
  size_t needed = 3;
  for (const char *p = text; *p; p++) needed += (*p == '\\' || *p == '"') ? 2 : 1;
  char *result = allocate(needed), *out = result;
  *out++ = '"';
  for (const char *p = text; *p; p++) {
    if (*p == '\\' || *p == '"') *out++ = '\\';
    *out++ = *p;
  }
  *out++ = '"'; *out = 0;
  return result;
}

static void write_all(int fd, const void *data, size_t length) {
  const char *cursor = data;
  while (length) {
    ssize_t count = write(fd, cursor, length);
    if (count < 0) die("cache write failed");
    cursor += count;
    length -= (size_t)count;
  }
}

static int identity_matches(const char *path, const char *identity, size_t length) {
  size_t stored_length = 0;
  char *stored = read_file(path, &stored_length);
  int equal = stored_length == length && !memcmp(stored, identity, length);
  free(stored);
  return equal;
}

static char *root_target(const char *root, const char *tool) {
  char target[PATH_MAX];
  ssize_t length = readlink(root, target, sizeof target - 1);
  if (length <= 0) return NULL;
  target[length] = 0;
  if (strncmp(target, "/gnu/store/", 11)) return NULL;
  char *binary_dir = join(target, "bin");
  char *binary = join(binary_dir, tool);
  free(binary_dir);
  if (access(binary, X_OK)) { free(binary); return NULL; }
  return binary;
}

static char *realize(const char *expression, const char *root) {
  int output[2];
  if (pipe(output)) die("pipe failed");
  pid_t child = fork();
  if (child < 0) die("fork failed");
  if (!child) {
    close(output[0]);
    if (dup2(output[1], STDOUT_FILENO) < 0) _exit(126);
    close(output[1]);
    char *load_path = join(PROVIDER, "guix");
    char *manifest_path = join(PROVIDER, "manifests");
    if (setenv("GUIX_RUST_TOOLCHAIN_INTERNAL_MANIFESTS", manifest_path, 1))
      _exit(126);
    size_t root_size = strlen(root) + 8;
    char *root_option = allocate(root_size);
    snprintf(root_option, root_size, "--root=%s", root);
    execl(GUIX, GUIX, "build", "-L", load_path, "-e", expression,
          root_option, (char *)NULL);
    _exit(127);
  }
  close(output[1]);
  char buffer[4096];
  while (read(output[0], buffer, sizeof buffer) > 0) { }
  close(output[0]);
  int status;
  if (waitpid(child, &status, 0) < 0) die("waitpid failed");
  if (!WIFEXITED(status) || WEXITSTATUS(status)) fail("Guix realization failed");
  return NULL;
}

int main(int argc, char **argv) {
  const char *invoked = strrchr(argv[0], '/');
  invoked = invoked ? invoked + 1 : argv[0];
  char tool[32], *selector = NULL;
  char *suffix = strrchr(invoked, '-');
  if (suffix && (!strcmp(suffix, "-stable") || !strcmp(suffix, "-nightly"))) {
    size_t tool_length = (size_t)(suffix - invoked);
    if (!tool_length || tool_length >= sizeof tool) fail("invalid proxy name");
    memcpy(tool, invoked, tool_length); tool[tool_length] = 0;
    selector = suffix + 1;
  } else {
    if (strlen(invoked) >= sizeof tool) fail("invalid proxy name");
    strcpy(tool, invoked);
  }
  if (strcmp(tool, "cargo") && strcmp(tool, "rustc") && strcmp(tool, "rustdoc"))
    fail("unsupported proxy name");
  int drop_override = 0;
  if (!selector && argc > 1 && argv[1][0] == '+' && argv[1][1]) {
    selector = argv[1] + 1;
    drop_override = 1;
  }

  char *config = NULL, *contents = NULL;
  size_t contents_length = 0, identity_length;
  char *identity;
  if (selector) {
    identity_length = strlen(selector) + 8;
    identity = allocate(identity_length + 1);
    identity_length = (size_t)sprintf(identity, "channel:%s", selector);
  } else if ((config = find_config())) {
    contents = read_file(config, &contents_length);
    identity_length = strlen(config) + contents_length + 7;
    identity = allocate(identity_length);
    int prefix = sprintf(identity, "file:%s\n", config);
    memcpy(identity + prefix, contents, contents_length);
    identity_length = (size_t)prefix + contents_length;
  } else {
    identity = strdup("channel:stable");
    identity_length = strlen(identity);
  }

  size_t provider_length = strlen(PROVIDER);
  char *request_identity = identity;
  identity = allocate(provider_length + identity_length + 11);
  int prefix = sprintf(identity, "provider:%s\n", PROVIDER);
  memcpy(identity + prefix, request_identity, identity_length);
  identity_length += (size_t)prefix;
  free(request_identity);

  uint64_t hash = hash_bytes(identity, identity_length, UINT64_C(1469598103934665603));
  const char *base = getenv("XDG_CACHE_HOME"), *home = getenv("HOME");
  char *fallback = NULL;
  if (!base || !base[0]) {
    if (!home || !home[0]) fail("HOME or XDG_CACHE_HOME is required");
    fallback = join(home, ".cache"); base = fallback;
  }
  mkdir_hierarchy(base);
  char *cache = join(base, "guix-rust-toolchain"); mkdir_if_missing(cache);
  char *entries = join(cache, "entries"); mkdir_if_missing(entries);
  char *roots = join(cache, "roots"); mkdir_if_missing(roots);
  char name[17]; snprintf(name, sizeof name, "%016llx", (unsigned long long)hash);
  char lock_name[22]; snprintf(lock_name, sizeof lock_name, "%s.lock", name);
  char *entry = join(entries, name), *root = join(roots, name);
  char *lock_path = join(entries, lock_name);
  int lock = open(lock_path, O_CREAT | O_RDWR | O_CLOEXEC, 0600);
  if (lock < 0 || flock(lock, LOCK_EX)) die("cannot lock proxy cache");

  char *binary = NULL;
  if (regular_file(entry) && identity_matches(entry, identity, identity_length))
    binary = root_target(root, tool);
  if (!binary) {
    unlink(root);
    char *argument;
    if (config) {
      int is_toml = strlen(config) >= 5 &&
                    !strcmp(config + strlen(config) - 5, ".toml");
      char request_name[32];
      snprintf(request_name, sizeof request_name, "%s%s", name,
               is_toml ? ".toml" : ".toolchain");
      char *request = join(entries, request_name);
      int request_fd = open(request, O_CREAT | O_TRUNC | O_WRONLY, 0600);
      if (request_fd < 0) die("cannot write toolchain request snapshot");
      write_all(request_fd, contents, contents_length); close(request_fd);
      char *quoted = scheme_string(request);
      size_t size = strlen(quoted) + 100;
      argument = allocate(size);
      snprintf(argument, size, "(begin (use-modules (rust-toolchain toolchain-file)) (rust-toolchain-from-file %s))", quoted);
      free(quoted);
    } else {
      char *quoted = scheme_string(selector ? selector : "stable");
      size_t size = strlen(quoted) + 80;
      argument = allocate(size);
      snprintf(argument, size, "(begin (use-modules (rust-toolchain package)) (rust-toolchain %s))", quoted);
      free(quoted);
    }
    realize(argument, root);
    int entry_fd = open(entry, O_CREAT | O_TRUNC | O_WRONLY, 0600);
    if (entry_fd < 0) die("cannot write proxy cache identity");
    write_all(entry_fd, identity, identity_length); close(entry_fd);
    binary = root_target(root, tool);
    if (!binary) fail("realized toolchain does not provide requested binary");
  }
  close(lock);
  if (drop_override) { argv[1] = argv[0]; argv++; argc--; argv[0] = (char *)tool; }
  else argv[0] = (char *)tool;
  execv(binary, argv);
  die("cannot execute realized Rust tool");
}
