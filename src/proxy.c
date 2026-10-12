/* SPDX-License-Identifier: GPL-3.0-or-later */
#define _GNU_SOURCE
#include <errno.h>
#include <dirent.h>
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
#ifndef DEFAULT_STABLE
#define DEFAULT_STABLE NULL
#endif
#ifndef DEFAULT_NIGHTLY
#define DEFAULT_NIGHTLY NULL
#endif

static const char analyzer_components[] =
  "components:rust-analyzer-preview,rust-src\n";
static const char host_suffix[] = "-x86_64-unknown-linux-gnu";

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
  if (!mkdir(path, 0700)) return;
  if (errno != EEXIST) die("cannot create cache directory");
  struct stat status;
  if (lstat(path, &status) || !S_ISDIR(status.st_mode)) {
    errno = ENOTDIR;
    die("unsafe cache directory component");
  }
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

static char *read_file(const char *path, size_t *length, int nofollow) {
  int fd = open(path, O_RDONLY | (nofollow ? O_NOFOLLOW : 0));
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

static char *read_cache_file(const char *path, size_t *length) {
  int fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
  if (fd < 0) return NULL;
  struct stat status;
  if (fstat(fd, &status) || !S_ISREG(status.st_mode) || status.st_size < 0 ||
      (uintmax_t)status.st_size > SIZE_MAX - 1) {
    close(fd);
    return NULL;
  }
  char *data = allocate((size_t)status.st_size + 1);
  size_t used = 0;
  while (used < (size_t)status.st_size) {
    ssize_t count = read(fd, data + used, (size_t)status.st_size - used);
    if (count <= 0) {
      free(data);
      close(fd);
      return NULL;
    }
    used += (size_t)count;
  }
  close(fd);
  data[used] = 0;
  *length = used;
  return data;
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
  char *stored = read_file(path, &stored_length, 1);
  int equal = stored_length == length && !memcmp(stored, identity, length);
  free(stored);
  return equal;
}

static char *store_target(const char *target, const char *tool);

static char *root_target(const char *root, const char *tool) {
  char target[PATH_MAX];
  ssize_t length = readlink(root, target, sizeof target - 1);
  if (length <= 0) return NULL;
  target[length] = 0;
  return store_target(target, tool);
}

static int store_item(const char *path) {
  if (strncmp(path, "/gnu/store/", 11)) return 0;
  const char *name = path + 11;
  for (size_t index = 0; index < 32; index++) {
    char character = name[index];
    if (!((character >= '0' && character <= '9') ||
          (character >= 'a' && character <= 'z'))) return 0;
  }
  return name[32] == '-' && name[33] && !strchr(name + 33, '/');
}

static char *store_target(const char *target, const char *tool) {
  struct stat status;
  if (!store_item(target) || stat(target, &status) || !S_ISDIR(status.st_mode))
    return NULL;
  char *binary_dir = join(target, "bin");
  char *binary = join(binary_dir, tool);
  free(binary_dir);
  if (access(binary, X_OK)) { free(binary); return NULL; }
  return binary;
}

static int cache_name(const char *name) {
  if (strlen(name) != 16) return 0;
  for (size_t index = 0; index < 16; index++) {
    char character = name[index];
    if (!((character >= '0' && character <= '9') ||
          (character >= 'a' && character <= 'f'))) return 0;
  }
  return 1;
}

static size_t selector_length_without_host(const char *selector, size_t length) {
  size_t suffix_length = sizeof host_suffix - 1;
  if (length >= suffix_length &&
      !memcmp(selector + length - suffix_length, host_suffix, suffix_length))
    return length - suffix_length;
  return length;
}

static int decimal_component(const char *text, size_t length) {
  if (!length) return 0;
  for (size_t index = 0; index < length; index++)
    if (text[index] < '0' || text[index] > '9') return 0;
  return 1;
}

static int stable_selector(const char *selector, size_t length) {
  length = selector_length_without_host(selector, length);
  size_t start = 0;
  for (size_t component = 0; component < 3; component++) {
    size_t end = start;
    while (end < length && selector[end] != '.') end++;
    if (!decimal_component(selector + start, end - start)) return 0;
    if (component < 2 && (end == length || selector[end] != '.')) return 0;
    start = end + 1;
  }
  return start == length + 1;
}

static int nightly_selector(const char *selector, size_t length) {
  length = selector_length_without_host(selector, length);
  if (length != 18 || memcmp(selector, "nightly-", 8)) return 0;
  for (size_t index = 8; index < length; index++) {
    if (index == 12 || index == 15) {
      if (selector[index] != '-') return 0;
    } else if (selector[index] < '0' || selector[index] > '9') return 0;
  }
  return 1;
}

static int compare_decimal(const char *left, size_t left_length,
                           const char *right, size_t right_length) {
  while (left_length > 1 && *left == '0') { left++; left_length--; }
  while (right_length > 1 && *right == '0') { right++; right_length--; }
  if (left_length != right_length) return left_length > right_length ? 1 : -1;
  int result = memcmp(left, right, left_length);
  return result > 0 ? 1 : result < 0 ? -1 : 0;
}

static int compare_stable_selectors(const char *left, const char *right) {
  size_t left_length = selector_length_without_host(left, strlen(left));
  size_t right_length = selector_length_without_host(right, strlen(right));
  size_t left_start = 0, right_start = 0;
  for (size_t component = 0; component < 3; component++) {
    size_t left_end = left_start, right_end = right_start;
    while (left_end < left_length && left[left_end] != '.') left_end++;
    while (right_end < right_length && right[right_end] != '.') right_end++;
    int result = compare_decimal(left + left_start, left_end - left_start,
                                 right + right_start, right_end - right_start);
    if (result) return result;
    left_start = left_end + 1;
    right_start = right_end + 1;
  }
  return 0;
}

static char *cached_default(const char *entries, const char *roots,
                            const char *tool, const char *kind) {
  DIR *directory = opendir(entries);
  if (!directory) return NULL;
  int analyzer = !strcmp(tool, "rust-analyzer");
  char *best = NULL;
  struct dirent *item;
  while ((item = readdir(directory))) {
    if (!cache_name(item->d_name)) continue;
    char *entry = join(entries, item->d_name);
    size_t length = 0;
    char *identity = read_cache_file(entry, &length);
    if (!identity) { free(entry); continue; }
    uint64_t hash = hash_bytes(identity, length, UINT64_C(1469598103934665603));
    char expected[17];
    snprintf(expected, sizeof expected, "%016llx", (unsigned long long)hash);
    if (strcmp(expected, item->d_name)) { free(identity); free(entry); continue; }
    const char *first = strchr(identity, '\n');
    const char *second = first ? strchr(first + 1, '\n') : NULL;
    const char *prefix = second ? second + 1 : NULL;
    if (!first || !second || strncmp(identity, "provider:/gnu/store/", 20) ||
        strncmp(first + 1, "guix:/gnu/store/", 16) ||
        !prefix || strncmp(prefix, "channel:", 8)) {
      free(identity); free(entry); continue;
    }
    const char *selector = prefix + 8;
    size_t selector_length = length - (size_t)(selector - identity);
    if (analyzer) {
      size_t components_length = sizeof analyzer_components - 1;
      if (selector_length < components_length ||
          memcmp(selector + selector_length - components_length,
                 analyzer_components, components_length)) {
        free(identity); free(entry); continue;
      }
      selector_length -= components_length;
    } else if (memchr(selector, '\n', selector_length)) {
      free(identity); free(entry); continue;
    }
    int matching = !strcmp(kind, "stable")
      ? stable_selector(selector, selector_length)
      : nightly_selector(selector, selector_length);
    char *root = join(roots, item->d_name);
    char *binary = matching ? root_target(root, tool) : NULL;
    free(root);
    if (binary) {
      char *candidate = allocate(selector_length + 1);
      memcpy(candidate, selector, selector_length);
      candidate[selector_length] = 0;
      int newer = !best || (!strcmp(kind, "stable")
                            ? compare_stable_selectors(candidate, best) > 0
                            : strcmp(candidate, best) > 0);
      if (newer) { free(best); best = candidate; }
      else free(candidate);
      free(binary);
    }
    free(identity);
    free(entry);
  }
  closedir(directory);
  return best;
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
  char tool[32];
  const char *selector = NULL;
  int environment_selector = 0;
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
  if (strcmp(tool, "cargo") && strcmp(tool, "rustc") && strcmp(tool, "rustdoc") &&
      strcmp(tool, "rust-analyzer"))
    fail("unsupported proxy name");
  int drop_override = 0;
  if (!selector && argc > 1 && argv[1][0] == '+' && argv[1][1]) {
    selector = argv[1] + 1;
    drop_override = 1;
  }
  if (!selector) {
    char *environment = getenv("RUSTUP_TOOLCHAIN");
    if (environment && environment[0]) {
      selector = environment;
      environment_selector = 1;
    }
  }
  if (environment_selector) {
    char *binary = store_target(selector, tool);
    if (binary) {
      argv[0] = (char *)tool;
      execv(binary, argv);
      die("cannot execute selected Rust tool");
    }
  }

  char *config = NULL, *contents = NULL;
  size_t contents_length = 0, identity_length;
  char *identity;
  if (!selector && (config = find_config())) {
    contents = read_file(config, &contents_length, 0);
  } else if (!selector) {
    selector = "stable";
  }

  const char *base = getenv("XDG_CACHE_HOME"), *home = getenv("HOME");
  char *fallback = NULL;
  if (!base || !base[0]) {
    if (!home || !home[0]) fail("HOME or XDG_CACHE_HOME is required");
    fallback = join(home, ".cache"); base = fallback;
  }
  if (base[0] != '/') fail("XDG cache directory must be absolute");
  mkdir_hierarchy(base);
  char *cache = join(base, "guix-rust-toolchain"); mkdir_if_missing(cache);
  char *entries = join(cache, "entries"); mkdir_if_missing(entries);
  char *roots = join(cache, "roots"); mkdir_if_missing(roots);

  char *cached_selector = NULL;
  if (!config && (!strcmp(selector, "stable") || !strcmp(selector, "nightly"))) {
    const char *configured = !strcmp(selector, "stable")
      ? DEFAULT_STABLE : DEFAULT_NIGHTLY;
    if (configured) selector = configured;
    else if ((cached_selector = cached_default(entries, roots, tool, selector)))
      selector = cached_selector;
  }

  if (config) {
    identity_length = strlen(config) + contents_length + 7;
    identity = allocate(identity_length);
    int prefix = sprintf(identity, "file:%s\n", config);
    memcpy(identity + prefix, contents, contents_length);
    identity_length = (size_t)prefix + contents_length;
  } else {
    identity_length = strlen(selector) + 8;
    identity = allocate(identity_length + 1);
    identity_length = (size_t)sprintf(identity, "channel:%s", selector);
  }
  if (!strcmp(tool, "rust-analyzer")) {
    char *requested = identity;
    identity = allocate(identity_length + sizeof analyzer_components);
    memcpy(identity, requested, identity_length);
    memcpy(identity + identity_length, analyzer_components,
           sizeof analyzer_components - 1);
    identity_length += sizeof analyzer_components - 1;
    free(requested);
  }

  size_t provider_length = strlen(PROVIDER), guix_length = strlen(GUIX);
  char *request_identity = identity;
  identity = allocate(provider_length + guix_length + identity_length + 17);
  int prefix = sprintf(identity, "provider:%s\nguix:%s\n", PROVIDER, GUIX);
  memcpy(identity + prefix, request_identity, identity_length);
  identity_length += (size_t)prefix;
  free(request_identity);

  uint64_t hash = hash_bytes(identity, identity_length, UINT64_C(1469598103934665603));
  char name[17]; snprintf(name, sizeof name, "%016llx", (unsigned long long)hash);
  char lock_name[22]; snprintf(lock_name, sizeof lock_name, "%s.lock", name);
  char *entry = join(entries, name), *root = join(roots, name);
  char *lock_path = join(entries, lock_name);
  int lock = open(lock_path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0600);
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
      int request_fd = open(request, O_CREAT | O_TRUNC | O_WRONLY | O_NOFOLLOW,
                            0600);
      if (request_fd < 0) die("cannot write toolchain request snapshot");
      write_all(request_fd, contents, contents_length); close(request_fd);
      char *quoted = scheme_string(request);
      size_t size = strlen(quoted) + 180;
      argument = allocate(size);
      if (!strcmp(tool, "rust-analyzer"))
        snprintf(argument, size, "(begin (use-modules (rust-toolchain toolchain-file)) (rust-toolchain-from-file %s #:extra-components '(\"rust-analyzer-preview\" \"rust-src\")))", quoted);
      else
        snprintf(argument, size, "(begin (use-modules (rust-toolchain toolchain-file)) (rust-toolchain-from-file %s))", quoted);
      free(quoted);
    } else {
      char *quoted = scheme_string(selector ? selector : "stable");
      size_t size = strlen(quoted) + 140;
      argument = allocate(size);
      if (!strcmp(tool, "rust-analyzer"))
        snprintf(argument, size, "(begin (use-modules (rust-toolchain package)) (rust-toolchain %s #:components '(\"rust-analyzer-preview\" \"rust-src\")))", quoted);
      else
        snprintf(argument, size, "(begin (use-modules (rust-toolchain package)) (rust-toolchain %s))", quoted);
      free(quoted);
    }
    realize(argument, root);
    int entry_fd = open(entry, O_CREAT | O_TRUNC | O_WRONLY | O_NOFOLLOW, 0600);
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
