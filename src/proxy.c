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
  return selector;
}

struct string_list {
  char **items;
  size_t count;
  size_t capacity;
  int specified;
};

struct request {
  char *contents;
  char *selector;
  char *profile;
  int validate_capabilities;
  struct string_list components;
  struct string_list targets;
};

static void skip_horizontal(char **text) {
  while (**text == ' ' || **text == '\t') (*text)++;
}

static void skip_line(char **text) {
  while (**text && **text != '\r' && **text != '\n') (*text)++;
  if (**text == '\r') (*text)++;
  if (**text == '\n') (*text)++;
}

static void finish_line(char **text, const char *field) {
  skip_horizontal(text);
  if (**text == '#') skip_line(text);
  else if (**text == '\r' || **text == '\n') skip_line(text);
  else if (**text) {
    fprintf(stderr, "guix-rust-toolchain: invalid toolchain %s in rust-toolchain.toml\n",
            field);
    exit(1);
  }
}

static char *toml_string(char **text, const char *field) {
  if (**text != '"') {
    fprintf(stderr, "guix-rust-toolchain: toolchain %s must be a string\n", field);
    exit(1);
  }
  char *value = ++*text;
  while (**text && **text != '"') {
    unsigned char character = (unsigned char)**text;
    if (**text == '\\' || character < 32 || character == 127) {
      fprintf(stderr, "guix-rust-toolchain: invalid toolchain %s string\n", field);
      exit(1);
    }
    (*text)++;
  }
  if (**text != '"') {
    fprintf(stderr, "guix-rust-toolchain: unterminated toolchain %s string\n", field);
    exit(1);
  }
  *(*text)++ = 0;
  if (!*value) {
    fprintf(stderr, "guix-rust-toolchain: empty toolchain %s\n", field);
    exit(1);
  }
  return value;
}

static void list_add(struct string_list *list, char *value) {
  if (list->count == list->capacity) {
    size_t capacity = list->capacity ? list->capacity * 2 : 4;
    if (capacity > SIZE_MAX / sizeof *list->items) die("out of memory");
    char **items = realloc(list->items, capacity * sizeof *items);
    if (!items) die("out of memory");
    list->items = items;
    list->capacity = capacity;
  }
  list->items[list->count++] = value;
}

static void skip_array_space(char **text) {
  for (;;) {
    while (**text == ' ' || **text == '\t' || **text == '\r' || **text == '\n') (*text)++;
    if (**text != '#') return;
    skip_line(text);
  }
}

static void toml_array(char **text, struct string_list *list, const char *field) {
  if (list->specified) {
    fprintf(stderr, "guix-rust-toolchain: multiple toolchain %s fields in rust-toolchain.toml\n",
            field);
    exit(1);
  }
  list->specified = 1;
  if (*(*text)++ != '[') fail("invalid toolchain array");
  skip_array_space(text);
  while (**text != ']') {
    if (!**text) {
      fprintf(stderr, "guix-rust-toolchain: unterminated toolchain %s array\n", field);
      exit(1);
    }
    char *value = toml_string(text, field);
    if (strchr(value, ',')) {
      fprintf(stderr, "guix-rust-toolchain: invalid toolchain %s string\n", field);
      exit(1);
    }
    list_add(list, value);
    skip_array_space(text);
    if (**text == ']') break;
    if (**text != ',') {
      fprintf(stderr, "guix-rust-toolchain: invalid toolchain %s array\n", field);
      exit(1);
    }
    (*text)++;
    skip_array_space(text);
  }
  (*text)++;
  finish_line(text, field);
}

static struct request *toml_request(char *contents) {
  struct request *request = allocate(sizeof *request);
  memset(request, 0, sizeof *request);
  request->contents = contents;
  request->validate_capabilities = 1;
  int in_toolchain = 0;
  char *text = contents;
  while (*text) {
    skip_horizontal(&text);
    if (*text == '#' || *text == '\r' || *text == '\n') {
      skip_line(&text);
      continue;
    }
    if (*text == '[') {
      if (!strncmp(text, "[toolchain]", 11)) {
        char *after = text + 11;
        skip_horizontal(&after);
        if (!*after || *after == '#' || *after == '\r' || *after == '\n') {
          in_toolchain = 1;
          text = after;
          finish_line(&text, "table");
          continue;
        }
      }
      in_toolchain = 0;
      skip_line(&text);
      continue;
    }
    if (!in_toolchain) {
      skip_line(&text);
      continue;
    }
    char *field = text;
    while ((*text >= 'a' && *text <= 'z') || (*text >= 'A' && *text <= 'Z') ||
           *text == '-' || *text == '_') text++;
    if (field == text) fail("invalid field in rust-toolchain.toml");
    char delimiter = *text;
    if (!delimiter) fail("invalid field in rust-toolchain.toml");
    *text = 0;
    text++;
    if (delimiter != '=') {
      skip_horizontal(&text);
      if (*text != '=') fail("invalid field in rust-toolchain.toml");
      text++;
    }
    skip_horizontal(&text);
    if (!strcmp(field, "channel")) {
      if (request->selector) fail("multiple toolchain channel fields in rust-toolchain.toml");
      request->selector = toml_string(&text, field);
      finish_line(&text, field);
    } else if (!strcmp(field, "profile")) {
      if (request->profile) fail("multiple toolchain profile fields in rust-toolchain.toml");
      request->profile = toml_string(&text, field);
      finish_line(&text, field);
    } else if (!strcmp(field, "components")) {
      toml_array(&text, &request->components, field);
    } else if (!strcmp(field, "targets")) {
      toml_array(&text, &request->targets, field);
    } else {
      fail("statically declared proxies support only toolchain.channel, profile, components, and targets");
    }
  }
  if (!request->selector) fail("rust-toolchain.toml must declare [toolchain].channel");
  if (!request->profile) request->profile = "default";
  return request;
}

static void free_request(struct request *request) {
  if (!request) return;
  free(request->components.items);
  free(request->targets.items);
  free(request->contents);
  free(request);
}

static struct request *request_from_config(const char *path) {
  size_t length = 0;
  char *contents = read_file(path, &length);
  (void)length;
  size_t path_length = strlen(path);
  int toml = path_length >= 5 && !strcmp(path + path_length - 5, ".toml");
  if (toml) return toml_request(contents);
  struct request *request = allocate(sizeof *request);
  memset(request, 0, sizeof *request);
  request->contents = contents;
  request->selector = legacy_selector(contents);
  return request;
}

static char *without_host_suffix(char *selector) {
  size_t length = strlen(selector);
  size_t suffix_length = sizeof host_suffix - 1;
  if (length >= suffix_length && !strcmp(selector + length - suffix_length, host_suffix))
    selector[length - suffix_length] = 0;
  return selector;
}

struct registry_entry {
  char *bin;
  char *profile;
  char *components;
  char *targets;
};

static void free_entry(struct registry_entry *entry) {
  if (!entry) return;
  free(entry->bin);
  free(entry->profile);
  free(entry->components);
  free(entry->targets);
  free(entry);
}

static struct registry_entry *lookup(const char *selector) {
  FILE *file = fopen(REGISTRY, "r");
  if (!file) die("cannot open declared toolchain registry");
  char *line = NULL;
  size_t capacity = 0;
  struct registry_entry *result = NULL;
  while (getline(&line, &capacity, file) >= 0) {
    char *newline = strpbrk(line, "\r\n");
    if (newline) *newline = 0;
    char *fields[5] = {line};
    size_t count = 1;
    for (char *separator = line; (separator = strchr(separator, '\t'));) {
      if (count == 5) fail("invalid declared toolchain registry");
      *separator = 0;
      fields[count++] = ++separator;
    }
    if (count != 5 || !fields[0][0] || !fields[1][0] || !fields[2][0])
      fail("invalid declared toolchain registry");
    if (!strcmp(line, selector)) {
      result = allocate(sizeof *result);
      result->bin = strdup(fields[1]);
      result->profile = strdup(fields[2]);
      result->components = strdup(fields[3]);
      result->targets = strdup(fields[4]);
      if (!result->bin || !result->profile || !result->components || !result->targets)
        die("out of memory");
      break;
    }
  }
  free(line);
  fclose(file);
  return result;
}

static int listed(const char *list, const char *value) {
  const char *item = list;
  size_t value_length = strlen(value);
  while (*item) {
    const char *end = strchr(item, ',');
    size_t length = end ? (size_t)(end - item) : strlen(item);
    if (length == value_length && !strncmp(item, value, length)) return 1;
    if (!end) break;
    item = end + 1;
  }
  return 0;
}

static void missing_capability(const char *selector, const char *kind, const char *value) {
  fprintf(stderr, "guix-rust-toolchain: declared toolchain '%s' does not provide requested %s '%s'\n",
          selector, kind, value);
  fprintf(stderr, "hint: install or enter an environment containing a matching "
          "rust-toolchain package\n");
  exit(1);
}

static void validate_request(const char *selector, const struct request *request,
                             const struct registry_entry *entry) {
  if (!request || !request->validate_capabilities) return;
  if (strcmp(request->profile, entry->profile))
    missing_capability(selector, "profile", request->profile);
  for (size_t index = 0; index < request->components.count; index++)
    if (!listed(entry->components, request->components.items[index]))
      missing_capability(selector, "component", request->components.items[index]);
  for (size_t index = 0; index < request->targets.count; index++)
    if (!listed(entry->targets, request->targets.items[index]))
      missing_capability(selector, "target", request->targets.items[index]);
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
  struct request *request = NULL;
  if (!selector && (config = find_config())) {
    request = request_from_config(config);
    selector = request->selector;
  } else if (!selector) {
    selector = "stable";
  }
  char *normalised = strdup(selector);
  if (!normalised) die("out of memory");
  without_host_suffix(normalised);
  struct registry_entry *entry = lookup(normalised);
  if (!entry) unavailable(normalised);
  validate_request(normalised, request, entry);
  char *binary = join(entry->bin, invoked);
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
  free_entry(entry);
  free_request(request);
  die("cannot execute selected Rust tool");
}
