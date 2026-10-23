/* SPDX-License-Identifier: GPL-3.0-or-later */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#ifndef REGISTRY
#error REGISTRY must name the declared toolchain registry
#endif

static const char host_suffix[] = "-x86_64-unknown-linux-gnu";

static void die(const char *message) {
  fprintf(stderr, "guix-rust-toolchain: %s: %s\n", message, strerror(errno));
  exit(1);
}

static void fail(const char *message) {
  fprintf(stderr, "guix-rust-toolchain: %s\n", message);
  exit(1);
}

static void unavailable(const char *selector) {
  fprintf(stderr, "guix-rust-toolchain: requested toolchain '%s' is not available\n",
          selector);
  fprintf(stderr, "hint: install or enter an environment containing a matching "
          "rust-toolchain package\n");
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

static char *read_file(const char *path, size_t *length) {
  int fd = open(path, O_RDONLY | O_CLOEXEC);
  if (fd < 0) die("cannot read selected toolchain file");
  struct stat status;
  if (fstat(fd, &status)) die("cannot stat selected toolchain file");
  if (!S_ISREG(status.st_mode) || status.st_size < 0 ||
      (uintmax_t)status.st_size > SIZE_MAX - 1)
    fail("selected toolchain file is not a regular file");
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

static char *trim(char *text) {
  while (*text == ' ' || *text == '\t' || *text == '\r' || *text == '\n') text++;
  char *end = text + strlen(text);
  while (end != text && (end[-1] == ' ' || end[-1] == '\t' ||
                         end[-1] == '\r' || end[-1] == '\n')) *--end = 0;
  return text;
}

static char *legacy_selector(char *contents) {
  char *selector = trim(contents);
  char *newline = strpbrk(selector, "\r\n");
  if (newline) {
    *newline = 0;
    if (*trim(newline + 1)) fail("legacy rust-toolchain file has multiple lines");
  }
  if (!*selector) fail("empty rust-toolchain file");
  return strdup(selector);
}

static char *toml_selector(char *contents) {
  int in_toolchain = 0;
  char *selector = NULL;
  char *line = contents;
  while (line && *line) {
    char *next = strpbrk(line, "\r\n");
    if (next) {
      char separator = *next;
      *next = 0;
      next += separator == '\r' && next[1] == '\n' ? 2 : 1;
    }
    char *text = trim(line);
    if (!strcmp(text, "[toolchain]")) {
      in_toolchain = 1;
    } else if (text[0] == '[') {
      in_toolchain = 0;
    } else if (in_toolchain && !strncmp(text, "channel", 7) &&
               (text[7] == ' ' || text[7] == '\t' || text[7] == '=')) {
      char *value = trim(text + 7);
      if (*value != '=') fail("invalid toolchain channel in rust-toolchain.toml");
      value = trim(value + 1);
      if (*value != '"') fail("toolchain channel must be a string");
      value++;
      char *end = strchr(value, '"');
      if (!end || *trim(end + 1)) fail("invalid toolchain channel in rust-toolchain.toml");
      *end = 0;
      if (!*value) fail("empty toolchain channel in rust-toolchain.toml");
      if (selector) fail("multiple toolchain channel fields in rust-toolchain.toml");
      selector = strdup(value);
      if (!selector) die("out of memory");
    } else if (in_toolchain && text[0] && text[0] != '#') {
      fail("statically declared proxies support only toolchain.channel");
    }
    line = next;
  }
  if (!selector) fail("rust-toolchain.toml must declare [toolchain].channel");
  return selector;
}

static char *selector_from_config(const char *path) {
  size_t length = 0;
  char *contents = read_file(path, &length);
  (void)length;
  size_t path_length = strlen(path);
  int toml = path_length >= 5 && !strcmp(path + path_length - 5, ".toml");
  char *selector = toml ? toml_selector(contents) : legacy_selector(contents);
  free(contents);
  return selector;
}

static char *without_host_suffix(char *selector) {
  size_t length = strlen(selector);
  size_t suffix_length = sizeof host_suffix - 1;
  if (length >= suffix_length && !strcmp(selector + length - suffix_length, host_suffix))
    selector[length - suffix_length] = 0;
  return selector;
}

static char *lookup(const char *selector) {
  FILE *file = fopen(REGISTRY, "r");
  if (!file) die("cannot open declared toolchain registry");
  char *line = NULL;
  size_t capacity = 0;
  char *result = NULL;
  while (getline(&line, &capacity, file) >= 0) {
    char *newline = strpbrk(line, "\r\n");
    if (newline) *newline = 0;
    char *separator = strchr(line, '\t');
    if (!separator || !separator[1] || strchr(separator + 1, '\t'))
      fail("invalid declared toolchain registry");
    *separator = 0;
    if (!strcmp(line, selector)) {
      result = strdup(separator + 1);
      if (!result) die("out of memory");
      break;
    }
  }
  free(line);
  fclose(file);
  return result;
}

int main(int argc, char **argv) {
  const char *invoked = strrchr(argv[0], '/');
  invoked = invoked ? invoked + 1 : argv[0];
  if (strcmp(invoked, "cargo") && strcmp(invoked, "rustc") &&
      strcmp(invoked, "rustdoc") && strcmp(invoked, "rust-analyzer"))
    fail("unsupported proxy name");

  const char *selector = NULL;
  int drop_override = 0;
  if (argc > 1 && argv[1][0] == '+' && argv[1][1]) {
    selector = argv[1] + 1;
    drop_override = 1;
  }
  if (!selector) {
    char *environment = getenv("RUSTUP_TOOLCHAIN");
    if (environment && environment[0]) selector = environment;
  }

  char *config = NULL;
  char *owned_selector = NULL;
  if (!selector && (config = find_config())) {
    owned_selector = selector_from_config(config);
    selector = owned_selector;
  } else if (!selector) {
    selector = "stable";
  }
  char *normalised = strdup(selector);
  if (!normalised) die("out of memory");
  without_host_suffix(normalised);
  char *bin = lookup(normalised);
  if (!bin) unavailable(normalised);
  char *binary = join(bin, invoked);
  if (access(binary, X_OK)) {
    fprintf(stderr, "guix-rust-toolchain: declared toolchain '%s' does not provide %s\n",
            normalised, invoked);
    exit(1);
  }
  if (drop_override) {
    argv[1] = argv[0];
    argv++;
    argc--;
  }
  (void)argc;
  argv[0] = (char *)invoked;
  execv(binary, argv);
  die("cannot execute selected Rust tool");
}
