#define _NETBSD_SOURCE 1

#include "json.h"
#include "../../protocol/c/nvza_protocol.h"

#include <sys/types.h>
#include <sys/event.h>
#include <sys/ioctl.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/wait.h>

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <limits.h>
#include <pwd.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <termios.h>
#include <unistd.h>
#include <util.h>

#ifdef __NetBSD__
#include <sys/reboot.h>
#endif

#ifndef O_DIRECTORY
#define O_DIRECTORY 0
#endif
#ifndef O_NOFOLLOW
#define O_NOFOLLOW 0
#endif

#define AGENT_BUILD "netbsd-vz-agent/0.1"
#define MAX_PROCESSES 64
#define MAX_JSON_TOKENS 4096
#define MAX_GROUPS 64
#define MAX_RLIMITS 32

extern char **environ;

struct configured_rlimit {
	int resource;
	struct rlimit value;
};

struct process_config {
	char *executable;
	char **argv;
	char **envp;
	char *cwd;
	char *login_name;
	uid_t uid;
	gid_t gid;
	gid_t groups[MAX_GROUPS];
	size_t group_count;
	struct configured_rlimit rlimits[MAX_RLIMITS];
	size_t rlimit_count;
	int terminal;
	unsigned short columns;
	unsigned short rows;
};

struct process {
	uint64_t id;
	struct process_config config;
	pid_t pid;
	int started;
	int child_exited;
	int finalized;
	int exit_code;
	int stdin_fd;
	int stdout_fd;
	int stderr_fd;
	int stdout_eof;
	int stderr_eof;
	uint64_t wait_request;
};

struct copy_transfer {
	uint64_t request_id;
	int fd;
	uint64_t remaining;
	mode_t mode;
};

static int serial_fd = -1;
static int event_queue = -1;
static int handshake_complete;
static struct process processes[MAX_PROCESSES];
static struct copy_transfer copies[MAX_PROCESSES];

static void
log_errno(const char *message)
{
	int saved = errno;
	fprintf(stderr, "netbsd-vz-agent: %s: %s\n", message, strerror(saved));
}

static int
write_all(int fd, const void *bytes, size_t length)
{
	const unsigned char *cursor = bytes;
	ssize_t written;

	while (length != 0) {
		written = write(fd, cursor, length);
		if (written < 0) {
			if (errno == EINTR) continue;
			return -1;
		}
		if (written == 0) { errno = EIO; return -1; }
		cursor += written;
		length -= (size_t)written;
	}
	return 0;
}

static int
send_frame(uint16_t type, uint32_t flags, uint64_t request_id,
    uint64_t process_id, const void *payload, size_t length)
{
	struct nvza_header header;
	uint8_t encoded[NVZA_HEADER_SIZE];

	if (length > UINT32_MAX) { errno = EMSGSIZE; return -1; }
	header.version = NVZA_VERSION;
	header.type = type;
	header.flags = flags;
	header.request_id = request_id;
	header.process_id = process_id;
	header.payload_length = (uint32_t)length;
	if (nvza_header_encode(encoded, &header) != 0 ||
	    write_all(serial_fd, encoded, sizeof(encoded)) != 0 ||
	    (length != 0 && write_all(serial_fd, payload, length) != 0))
		return -1;
	return 0;
}

static int
send_json(uint16_t type, uint64_t request_id, uint64_t process_id,
    const char *json)
{
	return send_frame(type, 0, request_id, process_id, json, strlen(json));
}

static int
send_ok(uint64_t request_id, uint64_t process_id, const char *fields)
{
	char message[512];
	if (fields != NULL && fields[0] != '\0')
		(void)snprintf(message, sizeof(message), "{\"ok\":true,%s}", fields);
	else
		(void)strlcpy(message, "{\"ok\":true}", sizeof(message));
	return send_json(NVZA_FRAME_RESPONSE, request_id, process_id, message);
}

static int
send_error(uint64_t request_id, uint64_t process_id, const char *code,
    const char *message)
{
	char json[512];
	(void)snprintf(json, sizeof(json),
	    "{\"ok\":false,\"code\":\"%s\",\"message\":\"%s\"}",
	    code, message);
	return send_json(NVZA_FRAME_ERROR, request_id, process_id, json);
}

static void
free_strings(char **values)
{
	size_t i;
	if (values == NULL) return;
	for (i = 0; values[i] != NULL; i++) free(values[i]);
	free(values);
}

static void
free_config(struct process_config *config)
{
	free(config->executable);
	free_strings(config->argv);
	free_strings(config->envp);
	free(config->cwd);
	free(config->login_name);
	memset(config, 0, sizeof(*config));
}

static struct process *
find_process(uint64_t id)
{
	int i;
	for (i = 0; i < MAX_PROCESSES; i++)
		if (processes[i].id == id) return &processes[i];
	return NULL;
}

static struct process *
new_process(uint64_t id)
{
	int i;
	if (id == 0 || find_process(id) != NULL) return NULL;
	for (i = 0; i < MAX_PROCESSES; i++) {
		if (processes[i].id == 0) {
			memset(&processes[i], 0, sizeof(processes[i]));
			processes[i].id = id;
			processes[i].pid = -1;
			processes[i].stdin_fd = -1;
			processes[i].stdout_fd = -1;
			processes[i].stderr_fd = -1;
			return &processes[i];
		}
	}
	return NULL;
}

static int
token_index(const char *json, struct nvza_json_token *tokens, int object,
    const char *key, int required)
{
	int index = nvza_json_object_get(json, tokens, object, key);
	if (required && index < 0) errno = EINVAL;
	return index;
}

static int
parse_uint(const char *json, struct nvza_json_token *tokens, int object,
    const char *key, uint64_t default_value, uint64_t *value)
{
	int index = token_index(json, tokens, object, key, 0);
	if (index < 0) { *value = default_value; return 0; }
	return nvza_json_uint64(json, &tokens[index], value);
}

static int
parse_bool_value(const char *json, struct nvza_json_token *tokens, int object,
    const char *key, int default_value, int *value)
{
	int index = token_index(json, tokens, object, key, 0);
	if (index < 0) { *value = default_value; return 0; }
	return nvza_json_bool(json, &tokens[index], value);
}

static int
parse_string_array(const char *json, struct nvza_json_token *tokens, int array,
    char ***out, const char *prefix)
{
	char **values;
	int i, token;
	size_t count, offset = prefix == NULL ? 0 : 1;

	if (array < 0 || tokens[array].type != NVZA_JSON_ARRAY) { errno = EINVAL; return -1; }
	count = (size_t)tokens[array].children;
	values = calloc(count + offset + 1, sizeof(*values));
	if (values == NULL) return -1;
	if (prefix != NULL && (values[0] = strdup(prefix)) == NULL) { free(values); return -1; }
	for (i = 0; i < (int)count; i++) {
		token = nvza_json_array_get(tokens, array, i);
		values[i + offset] = nvza_json_string_dup(json, &tokens[token]);
		if (values[i + offset] == NULL) { free_strings(values); return -1; }
	}
	*out = values;
	return 0;
}

static int
rlimit_resource(const char *name)
{
	if (strcmp(name, "cpu") == 0) return RLIMIT_CPU;
	if (strcmp(name, "fsize") == 0) return RLIMIT_FSIZE;
	if (strcmp(name, "data") == 0) return RLIMIT_DATA;
	if (strcmp(name, "stack") == 0) return RLIMIT_STACK;
	if (strcmp(name, "core") == 0) return RLIMIT_CORE;
	if (strcmp(name, "rss") == 0) return RLIMIT_RSS;
	if (strcmp(name, "nofile") == 0) return RLIMIT_NOFILE;
	if (strcmp(name, "nproc") == 0) return RLIMIT_NPROC;
#ifdef RLIMIT_AS
	if (strcmp(name, "as") == 0) return RLIMIT_AS;
#endif
	return -1;
}

static int
numeric_id(const char *text, unsigned long *value)
{
	char *end;
	unsigned long parsed;

	if (text == NULL || *text == '\0') return 0;
	errno = 0;
	parsed = strtoul(text, &end, 10);
	if (errno != 0 || *end != '\0' || parsed > UINT_MAX) return 0;
	*value = parsed;
	return 1;
}

static int
add_group(struct process_config *config, gid_t group)
{
	size_t i;
	for (i = 0; i < config->group_count; i++)
		if (config->groups[i] == group) return 0;
	if (config->group_count == MAX_GROUPS) { errno = E2BIG; return -1; }
	config->groups[config->group_count++] = group;
	return 0;
}

static int
resolve_user(const char *expression, struct process_config *config)
{
	char *copy, *group_text, *separator;
	struct passwd *password = NULL;
	struct group *group;
	unsigned long value;
	int group_count;
	gid_t resolved[MAX_GROUPS];

	copy = strdup(expression);
	if (copy == NULL) return -1;
	separator = strchr(copy, ':');
	group_text = NULL;
	if (separator != NULL) {
		*separator = '\0';
		group_text = separator + 1;
		if (*group_text == '\0' || strchr(group_text, ':') != NULL) goto invalid;
	}
	if (*copy == '\0') goto invalid;
	if (numeric_id(copy, &value)) {
		config->uid = (uid_t)value;
		password = getpwuid(config->uid);
	} else {
		password = getpwnam(copy);
		if (password == NULL) goto invalid;
		config->uid = password->pw_uid;
	}
	if (password != NULL) {
		config->login_name = strdup(password->pw_name);
		if (config->login_name == NULL) { free(copy); return -1; }
	}
	if (group_text != NULL) {
		if (numeric_id(group_text, &value)) config->gid = (gid_t)value;
		else {
			group = getgrnam(group_text);
			if (group == NULL) goto invalid;
			config->gid = group->gr_gid;
		}
	} else config->gid = password == NULL ? 0 : password->pw_gid;

	if (config->login_name != NULL) {
		group_count = MAX_GROUPS;
		if (getgrouplist(config->login_name, config->gid, resolved, &group_count) < 0)
			goto invalid;
		while (group_count > 0)
			if (add_group(config, resolved[--group_count]) != 0) goto invalid;
	}
	free(copy);
	return 0;
invalid:
	free(copy);
	errno = EINVAL;
	return -1;
}

static int
parse_process_config(const char *json, struct nvza_json_token *tokens,
    int object, struct process_config *config)
{
	int index, i, child, resource_token;
	uint64_t value, soft, hard;
	char *resource;

	memset(config, 0, sizeof(*config));
	config->columns = 80;
	config->rows = 24;
	index = token_index(json, tokens, object, "executable", 1);
	if (index < 0 || (config->executable = nvza_json_string_dup(json, &tokens[index])) == NULL)
		goto fail;
	index = token_index(json, tokens, object, "arguments", 0);
	if (index < 0) {
		config->argv = calloc(2, sizeof(char *));
		if (config->argv == NULL || (config->argv[0] = strdup(config->executable)) == NULL) goto fail;
	} else if (parse_string_array(json, tokens, index, &config->argv, config->executable) != 0) goto fail;
	index = token_index(json, tokens, object, "environment", 0);
	if (index < 0) {
		config->envp = calloc(1, sizeof(char *));
		if (config->envp == NULL) goto fail;
	} else if (parse_string_array(json, tokens, index, &config->envp, NULL) != 0) goto fail;
	index = token_index(json, tokens, object, "workingDirectory", 0);
	if (index < 0) config->cwd = strdup("/");
	else config->cwd = nvza_json_string_dup(json, &tokens[index]);
	if (config->cwd == NULL) goto fail;
	index = token_index(json, tokens, object, "user", 0);
	if (index >= 0) {
		char *user = nvza_json_string_dup(json, &tokens[index]);
		if (user == NULL || resolve_user(user, config) != 0) { free(user); goto fail; }
		free(user);
	} else {
		if (parse_uint(json, tokens, object, "uid", 0, &value) != 0 || value > UINT_MAX) goto fail;
		config->uid = (uid_t)value;
		if (parse_uint(json, tokens, object, "gid", 0, &value) != 0 || value > UINT_MAX) goto fail;
		config->gid = (gid_t)value;
	}
	if (parse_bool_value(json, tokens, object, "terminal", 0, &config->terminal) != 0) goto fail;
	if (parse_uint(json, tokens, object, "columns", 80, &value) != 0 || value == 0 || value > USHRT_MAX) goto fail;
	config->columns = (unsigned short)value;
	if (parse_uint(json, tokens, object, "rows", 24, &value) != 0 || value == 0 || value > USHRT_MAX) goto fail;
	config->rows = (unsigned short)value;

	index = token_index(json, tokens, object, "supplementalGroups", 0);
	if (index >= 0) {
		if (tokens[index].type != NVZA_JSON_ARRAY || tokens[index].children > MAX_GROUPS) goto fail;
		for (i = 0; i < tokens[index].children; i++) {
			child = nvza_json_array_get(tokens, index, i);
			if (nvza_json_uint64(json, &tokens[child], &value) != 0 || value > UINT_MAX) goto fail;
			if (add_group(config, (gid_t)value) != 0) goto fail;
		}
	}
	index = token_index(json, tokens, object, "rlimits", 0);
	if (index >= 0) {
		if (tokens[index].type != NVZA_JSON_ARRAY || tokens[index].children > MAX_RLIMITS) goto fail;
		for (i = 0; i < tokens[index].children; i++) {
			child = nvza_json_array_get(tokens, index, i);
			resource_token = token_index(json, tokens, child, "resource", 1);
			resource = resource_token < 0 ? NULL : nvza_json_string_dup(json, &tokens[resource_token]);
			if (resource == NULL) goto fail;
			config->rlimits[config->rlimit_count].resource = rlimit_resource(resource);
			free(resource);
			if (config->rlimits[config->rlimit_count].resource < 0 ||
			    parse_uint(json, tokens, child, "soft", 0, &soft) != 0 ||
			    parse_uint(json, tokens, child, "hard", 0, &hard) != 0) goto fail;
			config->rlimits[config->rlimit_count].value.rlim_cur = (rlim_t)soft;
			config->rlimits[config->rlimit_count].value.rlim_max = (rlim_t)hard;
			config->rlimit_count++;
		}
	}
	return 0;
fail:
	free_config(config);
	errno = EINVAL;
	return -1;
}

static const char *
environment_value(char *const envp[], const char *name)
{
	size_t i, length = strlen(name);
	for (i = 0; envp != NULL && envp[i] != NULL; i++)
		if (strncmp(envp[i], name, length) == 0 && envp[i][length] == '=')
			return envp[i] + length + 1;
	return NULL;
}

static void
exec_configured(const struct process_config *config)
{
	const char *path;
	char *paths, *cursor, *next, candidate[PATH_MAX];

	if (strchr(config->executable, '/') != NULL)
		execve(config->executable, config->argv, config->envp);
	else {
		path = environment_value(config->envp, "PATH");
		if (path == NULL || path[0] == '\0') path = "/bin:/usr/bin:/sbin:/usr/sbin";
		paths = strdup(path);
		if (paths != NULL) {
			for (cursor = paths; cursor != NULL; cursor = next) {
				next = strchr(cursor, ':');
				if (next != NULL) *next++ = '\0';
				(void)snprintf(candidate, sizeof(candidate), "%s%s%s",
				    cursor[0] == '\0' ? "." : cursor, "/", config->executable);
				execve(candidate, config->argv, config->envp);
				if (errno != ENOENT && errno != ENOTDIR) break;
			}
			free(paths);
		}
	}
	dprintf(STDERR_FILENO, "execve %s: %s\n", config->executable, strerror(errno));
	_exit(127);
}

static int
set_nonblocking(int fd)
{
	int flags = fcntl(fd, F_GETFL);
	return flags < 0 ? -1 : fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

static int
watch_read(int fd, struct process *process)
{
	struct kevent change;
	EV_SET(&change, (uintptr_t)fd, EVFILT_READ, EV_ADD | EV_ENABLE, 0, 0, process);
	return kevent(event_queue, &change, 1, NULL, 0, NULL);
}

static int
watch_exit(pid_t pid, struct process *process)
{
	struct kevent change;
	EV_SET(&change, (uintptr_t)pid, EVFILT_PROC, EV_ADD | EV_ENABLE | EV_ONESHOT,
	    NOTE_EXIT, 0, process);
	return kevent(event_queue, &change, 1, NULL, 0, NULL);
}

static void
child_setup(const struct process_config *config, int in_fd, int out_fd, int err_fd,
    int terminal)
{
	size_t i;
	if (terminal) {
		(void)setsid();
#ifdef TIOCSCTTY
		(void)ioctl(in_fd, TIOCSCTTY, NULL);
#endif
	} else {
		(void)setpgid(0, 0);
	}
	if (dup2(in_fd, STDIN_FILENO) < 0 || dup2(out_fd, STDOUT_FILENO) < 0 ||
	    dup2(err_fd, STDERR_FILENO) < 0) _exit(126);
	if (in_fd > STDERR_FILENO) close(in_fd);
	if (out_fd > STDERR_FILENO && out_fd != in_fd) close(out_fd);
	if (err_fd > STDERR_FILENO && err_fd != in_fd && err_fd != out_fd) close(err_fd);
	if (chdir(config->cwd) != 0) { dprintf(STDERR_FILENO, "chdir: %s\n", strerror(errno)); _exit(126); }
	for (i = 0; i < config->rlimit_count; i++)
		if (setrlimit(config->rlimits[i].resource, &config->rlimits[i].value) != 0) {
			dprintf(STDERR_FILENO, "setrlimit: %s\n", strerror(errno)); _exit(126);
		}
	if (setgroups((int)config->group_count, config->groups) != 0 ||
	    setgid(config->gid) != 0 || setuid(config->uid) != 0) {
		dprintf(STDERR_FILENO, "credentials: %s\n", strerror(errno)); _exit(126);
	}
	exec_configured(config);
}

static int
start_process(struct process *process)
{
	int in_pipe[2] = {-1, -1}, out_pipe[2] = {-1, -1}, err_pipe[2] = {-1, -1};
	int master = -1, slave = -1;
	struct winsize size;
	pid_t pid;

	memset(&size, 0, sizeof(size));
	size.ws_col = process->config.columns;
	size.ws_row = process->config.rows;
	if (process->config.terminal) {
		if (openpty(&master, &slave, NULL, NULL, &size) != 0) return -1;
	} else if (pipe(in_pipe) != 0 || pipe(out_pipe) != 0 || pipe(err_pipe) != 0) {
		goto fail;
	}
	pid = fork();
	if (pid < 0) goto fail;
	if (pid == 0) {
		if (process->config.terminal) {
			close(master);
			child_setup(&process->config, slave, slave, slave, 1);
		} else {
			close(in_pipe[1]); close(out_pipe[0]); close(err_pipe[0]);
			child_setup(&process->config, in_pipe[0], out_pipe[1], err_pipe[1], 0);
		}
		_exit(126);
	}
	process->pid = pid;
	process->started = 1;
	if (process->config.terminal) {
		close(slave);
		process->stdin_fd = master;
		process->stdout_fd = master;
		process->stderr_fd = -1;
		process->stderr_eof = 1;
		(void)send_frame(NVZA_FRAME_STREAM_EOF, 0, 0, process->id, "stderr", 6);
	} else {
		close(in_pipe[0]); close(out_pipe[1]); close(err_pipe[1]);
		process->stdin_fd = in_pipe[1];
		process->stdout_fd = out_pipe[0];
		process->stderr_fd = err_pipe[0];
	}
	(void)set_nonblocking(process->stdin_fd);
	(void)set_nonblocking(process->stdout_fd);
	if (process->stderr_fd >= 0) (void)set_nonblocking(process->stderr_fd);
	if (watch_exit(process->pid, process) != 0 ||
	    watch_read(process->stdout_fd, process) != 0 ||
	    (process->stderr_fd >= 0 && watch_read(process->stderr_fd, process) != 0))
		return -1;
	return 0;
fail:
	if (master >= 0) close(master);
	if (slave >= 0) close(slave);
	if (in_pipe[0] >= 0) close(in_pipe[0]);
	if (in_pipe[1] >= 0) close(in_pipe[1]);
	if (out_pipe[0] >= 0) close(out_pipe[0]);
	if (out_pipe[1] >= 0) close(out_pipe[1]);
	if (err_pipe[0] >= 0) close(err_pipe[0]);
	if (err_pipe[1] >= 0) close(err_pipe[1]);
	return -1;
}

static void
send_process_eof(struct process *process, int fd)
{
	if (fd == process->stdout_fd) {
		if (!process->stdout_eof)
			(void)send_frame(NVZA_FRAME_STREAM_EOF, 0, 0, process->id, "stdout", 6);
		process->stdout_eof = 1;
		if (process->stdin_fd == fd) process->stdin_fd = -1;
		close(process->stdout_fd);
		process->stdout_fd = -1;
	} else if (fd == process->stderr_fd) {
		if (!process->stderr_eof)
			(void)send_frame(NVZA_FRAME_STREAM_EOF, 0, 0, process->id, "stderr", 6);
		process->stderr_eof = 1;
		close(process->stderr_fd);
		process->stderr_fd = -1;
	}
}

static void
read_process_output(struct process *process, int fd)
{
	unsigned char buffer[NVZA_MAX_STREAM_PAYLOAD];
	ssize_t count;
	uint16_t type = fd == process->stderr_fd ? NVZA_FRAME_STDERR : NVZA_FRAME_STDOUT;

	for (;;) {
		count = read(fd, buffer, sizeof(buffer));
		if (count > 0) {
			if (send_frame(type, 0, 0, process->id, buffer, (size_t)count) != 0)
				log_errno("send output");
			continue;
		}
		/*
		 * A PTY master can report EIO between fork(2) and the child opening
		 * its slave.  That is not EOF: closing the master here sends SIGHUP
		 * to an otherwise healthy process.  Once the child has exited, EIO
		 * is the terminal equivalent of EOF and it is safe to finalize it.
		 */
		if (count < 0 && process->config.terminal && errno == EIO &&
		    !process->child_exited)
			break;
		if (count == 0 || (count < 0 && process->config.terminal &&
		    errno == EIO))
			send_process_eof(process, fd);
		else if (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)
			send_process_eof(process, fd);
		break;
	}
}

static void
finish_process_if_ready(struct process *process)
{
	char json[192];
	if (!process->child_exited || process->stdout_fd >= 0 || process->stderr_fd >= 0 || process->finalized)
		return;
	process->finalized = 1;
	(void)snprintf(json, sizeof(json), "{\"event\":\"exit\",\"exitCode\":%d}", process->exit_code);
	(void)send_json(NVZA_FRAME_EVENT, 0, process->id, json);
	if (process->wait_request != 0) {
		(void)snprintf(json, sizeof(json), "\"exitCode\":%d", process->exit_code);
		(void)send_ok(process->wait_request, process->id, json);
		process->wait_request = 0;
	}
}

static void
reap_children(void)
{
	int status, i;
	pid_t pid;
	for (;;) {
		pid = waitpid(-1, &status, WNOHANG);
		if (pid <= 0) break;
		for (i = 0; i < MAX_PROCESSES; i++) {
			if (processes[i].id != 0 && processes[i].pid == pid) {
				processes[i].child_exited = 1;
				processes[i].exit_code = WIFEXITED(status) ? WEXITSTATUS(status) :
				    (WIFSIGNALED(status) ? 128 + WTERMSIG(status) : 255);
				if (processes[i].stdin_fd >= 0 && processes[i].stdin_fd != processes[i].stdout_fd) {
					close(processes[i].stdin_fd); processes[i].stdin_fd = -1;
				}
				finish_process_if_ready(&processes[i]);
				break;
			}
		}
	}
}

static int
signal_process(struct process *process, int signal_number)
{
	if (kill(-process->pid, signal_number) == 0) return 0;
	if (errno == ESRCH && kill(process->pid, signal_number) == 0) return 0;
	return -1;
}

static int
valid_relative_path(const char *path)
{
	const char *cursor, *slash;
	size_t length;
	if (path == NULL || path[0] == '\0' || path[0] == '/') return 0;
	for (cursor = path; *cursor != '\0'; cursor = slash == NULL ? cursor + strlen(cursor) : slash + 1) {
		slash = strchr(cursor, '/');
		length = slash == NULL ? strlen(cursor) : (size_t)(slash - cursor);
		if (length == 0 || (length == 1 && cursor[0] == '.') ||
		    (length == 2 && cursor[0] == '.' && cursor[1] == '.')) return 0;
		if (slash == NULL) break;
	}
	return 1;
}

static int
open_parent(const char *path, int create_parents, int *parent_fd, char **leaf)
{
	char *copy, *cursor, *slash, *last;
	int fd, next;
	if (!valid_relative_path(path)) { errno = EINVAL; return -1; }
	copy = strdup(path);
	if (copy == NULL) return -1;
	last = strrchr(copy, '/');
	if (last == NULL) { *leaf = copy; copy = NULL; }
	else { *last++ = '\0'; *leaf = strdup(last); if (*leaf == NULL) { free(copy); return -1; } }
	fd = open("/", O_RDONLY | O_DIRECTORY);
	if (fd < 0) goto fail;
	if (copy != NULL) {
		for (cursor = copy; cursor != NULL && *cursor != '\0'; cursor = slash) {
			slash = strchr(cursor, '/');
			if (slash != NULL) *slash++ = '\0';
		next = openat(fd, cursor, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
		if (next < 0 && errno == ENOENT && create_parents) {
			if (mkdirat(fd, cursor, 0755) != 0 && errno != EEXIST) { close(fd); goto fail; }
			next = openat(fd, cursor, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
		}
			if (next < 0) { close(fd); goto fail; }
			close(fd); fd = next;
		}
	}
	free(copy);
	*parent_fd = fd;
	return 0;
fail:
	free(copy); free(*leaf); *leaf = NULL; return -1;
}

static struct copy_transfer *
copy_slot(uint64_t request_id, int create)
{
	int i;
	for (i = 0; i < MAX_PROCESSES; i++)
		if (copies[i].request_id == request_id) return &copies[i];
	if (!create) return NULL;
	for (i = 0; i < MAX_PROCESSES; i++)
		if (copies[i].request_id == 0) { copies[i].request_id = request_id; copies[i].fd = -1; return &copies[i]; }
	return NULL;
}

static char *
request_string(const char *json, struct nvza_json_token *tokens, int root,
    const char *key)
{
	int index = token_index(json, tokens, root, key, 1);
	return index < 0 ? NULL : nvza_json_string_dup(json, &tokens[index]);
}

struct json_builder {
	char *bytes;
	size_t length;
	size_t capacity;
};

static int
builder_reserve(struct json_builder *builder, size_t extra)
{
	size_t capacity, needed;
	char *replacement;
	if (extra > NVZA_MAX_CONTROL_PAYLOAD - builder->length) { errno = EMSGSIZE; return -1; }
	needed = builder->length + extra;
	if (needed <= builder->capacity) return 0;
	capacity = builder->capacity == 0 ? 1024 : builder->capacity;
	while (capacity < needed) {
		if (capacity > NVZA_MAX_CONTROL_PAYLOAD / 2) { capacity = NVZA_MAX_CONTROL_PAYLOAD; break; }
		capacity *= 2;
	}
	replacement = realloc(builder->bytes, capacity);
	if (replacement == NULL) return -1;
	builder->bytes = replacement;
	builder->capacity = capacity;
	return 0;
}

static int
builder_append(struct json_builder *builder, const char *value, size_t length)
{
	if (builder_reserve(builder, length) != 0) return -1;
	memcpy(builder->bytes + builder->length, value, length);
	builder->length += length;
	return 0;
}

static int
builder_literal(struct json_builder *builder, const char *value)
{
	return builder_append(builder, value, strlen(value));
}

static int
builder_format(struct json_builder *builder, const char *format, ...)
{
	char value[192];
	va_list arguments;
	int length;
	va_start(arguments, format);
	length = vsnprintf(value, sizeof(value), format, arguments);
	va_end(arguments);
	if (length < 0 || (size_t)length >= sizeof(value)) { errno = EOVERFLOW; return -1; }
	return builder_append(builder, value, (size_t)length);
}

static int
builder_json_string(struct json_builder *builder, const char *value)
{
	const unsigned char *cursor = (const unsigned char *)value;
	char escaped[7];
	if (builder_literal(builder, "\"") != 0) return -1;
	for (; *cursor != '\0'; cursor++) {
		switch (*cursor) {
		case '"': if (builder_literal(builder, "\\\"") != 0) return -1; break;
		case '\\': if (builder_literal(builder, "\\\\") != 0) return -1; break;
		case '\b': if (builder_literal(builder, "\\b") != 0) return -1; break;
		case '\f': if (builder_literal(builder, "\\f") != 0) return -1; break;
		case '\n': if (builder_literal(builder, "\\n") != 0) return -1; break;
		case '\r': if (builder_literal(builder, "\\r") != 0) return -1; break;
		case '\t': if (builder_literal(builder, "\\t") != 0) return -1; break;
		default:
			if (*cursor < 0x20) {
				(void)snprintf(escaped, sizeof(escaped), "\\u%04x", *cursor);
				if (builder_append(builder, escaped, 6) != 0) return -1;
			} else if (builder_append(builder, (const char *)cursor, 1) != 0) return -1;
		}
	}
	return builder_literal(builder, "\"");
}

static int
append_copy_entry(struct json_builder *builder, int directory_fd,
    const char *name, const char *response_path, int *first)
{
	char target[PATH_MAX + 1];
	const char *type;
	struct stat st;
	ssize_t target_length;
	if (fstatat(directory_fd, name, &st, AT_SYMLINK_NOFOLLOW) != 0) return -1;
	if (S_ISREG(st.st_mode)) type = "regular";
	else if (S_ISDIR(st.st_mode)) type = "directory";
	else if (S_ISLNK(st.st_mode)) type = "symlink";
	else { errno = EFTYPE; return -1; }
	if (!*first && builder_literal(builder, ",") != 0) return -1;
	*first = 0;
	if (builder_literal(builder, "{\"path\":") != 0 ||
	    builder_json_string(builder, response_path) != 0 ||
	    builder_literal(builder, ",\"type\":") != 0 ||
	    builder_json_string(builder, type) != 0 ||
	    builder_format(builder, ",\"mode\":%u,\"size\":%llu",
	    (unsigned)(st.st_mode & 07777),
	    (unsigned long long)(S_ISREG(st.st_mode) ? st.st_size : 0)) != 0)
		return -1;
	if (S_ISLNK(st.st_mode)) {
		target_length = readlinkat(directory_fd, name, target, PATH_MAX);
		if (target_length < 0 || target_length > PATH_MAX) return -1;
		target[target_length] = '\0';
		if (builder_literal(builder, ",\"linkTarget\":") != 0 ||
		    builder_json_string(builder, target) != 0) return -1;
	}
	return builder_literal(builder, "}");
}

static int
handle_copy_list(const struct nvza_frame *frame, const char *json,
    struct nvza_json_token *tokens, int root)
{
	char *path = NULL, *leaf = NULL;
	int parent = -1, directory = -1, first = 1;
	struct stat st;
	struct json_builder builder = {0};
	DIR *stream = NULL;
	struct dirent *entry;

	path = request_string(json, tokens, root, "path");
	if (path == NULL || open_parent(path, 0, &parent, &leaf) != 0 ||
	    fstatat(parent, leaf, &st, AT_SYMLINK_NOFOLLOW) != 0 ||
	    builder_literal(&builder, "{\"ok\":true,\"entries\":[") != 0 ||
	    append_copy_entry(&builder, parent, leaf, "", &first) != 0)
		goto fail;
	if (S_ISDIR(st.st_mode)) {
		directory = openat(parent, leaf, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
		if (directory < 0 || (stream = fdopendir(directory)) == NULL) goto fail;
		directory = -1;
		errno = 0;
		while ((entry = readdir(stream)) != NULL) {
			if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) continue;
			if (append_copy_entry(&builder, dirfd(stream), entry->d_name,
			    entry->d_name, &first) != 0) goto fail;
		}
		if (errno != 0) goto fail;
	}
	if (builder_literal(&builder, "]}") != 0 ||
	    send_frame(NVZA_FRAME_RESPONSE, 0, frame->header.request_id, 0,
	    builder.bytes, builder.length) != 0)
		goto fail;
	if (stream != NULL) closedir(stream);
	if (parent >= 0) close(parent);
	free(builder.bytes); free(leaf); free(path);
	return 0;
fail:
	if (stream != NULL) closedir(stream);
	if (directory >= 0) close(directory);
	if (parent >= 0) close(parent);
	free(builder.bytes); free(leaf); free(path);
	return send_error(frame->header.request_id, 0, "copy-list-failed",
	    "copy path was rejected, unreadable, or contained an unsupported file type");
}

static int
handle_copy_in(const struct nvza_frame *frame, const char *json,
    struct nvza_json_token *tokens, int root)
{
	char *path = NULL, *kind = NULL, *target = NULL, *leaf = NULL;
	int parent = -1, fd = -1, create_parents = 0;
	uint64_t mode, size;
	struct copy_transfer *copy;
	struct stat st;

	path = request_string(json, tokens, root, "path");
	kind = request_string(json, tokens, root, "entryType");
	if (path == NULL || kind == NULL ||
	    parse_bool_value(json, tokens, root, "createParents", 0, &create_parents) != 0 ||
	    parse_uint(json, tokens, root, "mode", 0644, &mode) != 0 || mode > 07777 ||
	    parse_uint(json, tokens, root, "size", 0, &size) != 0 ||
	    open_parent(path, create_parents, &parent, &leaf) != 0) goto fail;
	if (strcmp(kind, "directory") == 0) {
		if (mkdirat(parent, leaf, (mode_t)mode) != 0 && errno != EEXIST) goto fail;
		if (fstatat(parent, leaf, &st, AT_SYMLINK_NOFOLLOW) != 0 || !S_ISDIR(st.st_mode)) goto fail;
		(void)fchmodat(parent, leaf, (mode_t)mode, 0);
	} else if (strcmp(kind, "symlink") == 0) {
		target = request_string(json, tokens, root, "linkTarget");
		if (target == NULL) goto fail;
		(void)unlinkat(parent, leaf, 0);
		if (symlinkat(target, parent, leaf) != 0) goto fail;
	} else if (strcmp(kind, "regular") == 0) {
		copy = copy_slot(frame->header.request_id, 1);
		if (copy == NULL) { errno = ENOSPC; goto fail; }
		fd = openat(parent, leaf, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, (mode_t)mode);
		if (fd < 0) { memset(copy, 0, sizeof(*copy)); goto fail; }
		copy->fd = fd; copy->remaining = size; copy->mode = (mode_t)mode;
		fd = -1;
		if (size == 0) { (void)fchmod(copy->fd, copy->mode); close(copy->fd); memset(copy, 0, sizeof(*copy)); }
	} else { errno = EINVAL; goto fail; }
	close(parent); free(leaf); free(path); free(kind); free(target);
	return send_ok(frame->header.request_id, 0, NULL);
fail:
	if (fd >= 0) close(fd);
	if (parent >= 0) close(parent);
	free(leaf); free(path); free(kind); free(target);
	return send_error(frame->header.request_id, 0, "invalid-copy-entry", "copy-in entry was rejected");
}

static int
handle_copy_data(const struct nvza_frame *frame)
{
	struct copy_transfer *copy = copy_slot(frame->header.request_id, 0);
	char event[160];
	if (copy == NULL || frame->header.payload_length > copy->remaining)
		return send_error(frame->header.request_id, 0, "invalid-copy-data", "unexpected copy data");
	if (write_all(copy->fd, frame->payload, frame->header.payload_length) != 0)
		return send_error(frame->header.request_id, 0, "copy-write-failed", "copy data could not be written");
	copy->remaining -= frame->header.payload_length;
	if (copy->remaining == 0) {
		(void)fchmod(copy->fd, copy->mode); close(copy->fd);
		(void)snprintf(event, sizeof(event), "{\"event\":\"copyComplete\",\"requestID\":%llu}",
		    (unsigned long long)frame->header.request_id);
		memset(copy, 0, sizeof(*copy));
		return send_json(NVZA_FRAME_EVENT, 0, 0, event);
	}
	(void)snprintf(event, sizeof(event),
	    "{\"event\":\"copyProgress\",\"requestID\":%llu,\"remaining\":%llu}",
	    (unsigned long long)frame->header.request_id,
	    (unsigned long long)copy->remaining);
	return send_json(NVZA_FRAME_EVENT, 0, 0, event);
}

static int
handle_copy_out(const struct nvza_frame *frame, const char *json,
    struct nvza_json_token *tokens, int root)
{
	char *path = request_string(json, tokens, root, "path"), *leaf = NULL;
	char metadata[256];
	unsigned char data[NVZA_MAX_STREAM_PAYLOAD];
	int parent = -1, fd = -1;
	ssize_t count;
	struct stat st;
	if (path == NULL || open_parent(path, 0, &parent, &leaf) != 0 ||
	    (fd = openat(parent, leaf, O_RDONLY | O_NOFOLLOW)) < 0 || fstat(fd, &st) != 0 || !S_ISREG(st.st_mode))
		goto fail;
	(void)snprintf(metadata, sizeof(metadata),
	    "\"entryType\":\"regular\",\"mode\":%u,\"size\":%llu",
	    (unsigned)(st.st_mode & 07777), (unsigned long long)st.st_size);
	if (send_ok(frame->header.request_id, 0, metadata) != 0) goto fail;
	while ((count = read(fd, data, sizeof(data))) != 0) {
		if (count < 0) { if (errno == EINTR) continue; goto fail; }
		if (send_frame(NVZA_FRAME_COPY_DATA, 0, frame->header.request_id, 0, data, (size_t)count) != 0) goto fail;
	}
	(void)send_frame(NVZA_FRAME_STREAM_EOF, 0, frame->header.request_id, 0, "copy", 4);
	close(fd); close(parent); free(leaf); free(path); return 0;
fail:
	if (fd >= 0) close(fd);
	if (parent >= 0) close(parent);
	free(leaf);
	free(path);
	return send_error(frame->header.request_id, 0, "copy-read-failed", "copy-out path was rejected or unreadable");
}

static void
delete_process(struct process *process)
{
	if (process->stdin_fd >= 0) close(process->stdin_fd);
	if (process->stdout_fd >= 0 && process->stdout_fd != process->stdin_fd) close(process->stdout_fd);
	if (process->stderr_fd >= 0) close(process->stderr_fd);
	free_config(&process->config);
	memset(process, 0, sizeof(*process));
}

static int
handle_request(const struct nvza_frame *frame)
{
	struct nvza_json_token *tokens = NULL;
	char *json = NULL, *operation = NULL;
	int count, root = 0, process_token, result = 0;
	int64_t signal_number;
	uint64_t columns, rows;
	struct process *process;
	struct winsize size;
	char fields[128];

	json = malloc((size_t)frame->header.payload_length + 1);
	tokens = calloc(MAX_JSON_TOKENS, sizeof(*tokens));
	if (json == NULL || tokens == NULL) goto malformed;
	memcpy(json, frame->payload, frame->header.payload_length);
	json[frame->header.payload_length] = '\0';
	count = nvza_json_parse(json, frame->header.payload_length, tokens, MAX_JSON_TOKENS);
	(void)count;
	if (count < 1 || tokens[0].type != NVZA_JSON_OBJECT ||
	    (operation = request_string(json, tokens, root, "operation")) == NULL) goto malformed;

	if (strcmp(operation, "create") == 0) {
		process = new_process(frame->header.process_id);
		process_token = token_index(json, tokens, root, "process", 1);
		if (process == NULL || process_token < 0 ||
		    parse_process_config(json, tokens, process_token, &process->config) != 0) {
			if (process != NULL) delete_process(process);
			result = send_error(frame->header.request_id, frame->header.process_id,
			    "invalid-process", "process configuration was rejected");
		} else result = send_ok(frame->header.request_id, process->id, NULL);
	} else if ((process = find_process(frame->header.process_id)) == NULL &&
	    strcmp(operation, "ping") != 0 && strcmp(operation, "shutdown") != 0 &&
	    strcmp(operation, "copyIn") != 0 && strcmp(operation, "copyOut") != 0 &&
	    strcmp(operation, "copyList") != 0) {
		result = send_error(frame->header.request_id, frame->header.process_id,
		    "process-not-found", "unknown process identifier");
	} else if (strcmp(operation, "start") == 0) {
		if (process->started || start_process(process) != 0)
			result = send_error(frame->header.request_id, process->id, "start-failed", "process could not be started");
		else {
			(void)snprintf(fields, sizeof(fields), "\"pid\":%d", process->pid);
			result = send_ok(frame->header.request_id, process->id, fields);
		}
	} else if (strcmp(operation, "wait") == 0) {
		if (process->finalized) {
			(void)snprintf(fields, sizeof(fields), "\"exitCode\":%d", process->exit_code);
			result = send_ok(frame->header.request_id, process->id, fields);
		} else if (process->wait_request != 0)
			result = send_error(frame->header.request_id, process->id, "wait-exists", "a waiter is already registered");
		else process->wait_request = frame->header.request_id;
	} else if (strcmp(operation, "signal") == 0) {
		process_token = token_index(json, tokens, root, "signal", 1);
		if (process_token < 0 ||
		    nvza_json_int64(json, &tokens[process_token], &signal_number) != 0 ||
		    signal_number <= 0 || signal_number >= NSIG) {
			result = send_error(frame->header.request_id, process->id, "signal-failed", "signal was rejected");
		} else if (!process->started || process->child_exited ||
		    signal_process(process, (int)signal_number) != 0) {
			result = send_error(frame->header.request_id, process->id, "signal-failed", "signal was rejected");
		} else result = send_ok(frame->header.request_id, process->id, NULL);
	} else if (strcmp(operation, "resize") == 0) {
		if (!process->config.terminal || process->stdout_fd < 0 ||
		    parse_uint(json, tokens, root, "columns", 0, &columns) != 0 ||
		    parse_uint(json, tokens, root, "rows", 0, &rows) != 0 ||
		    columns == 0 || columns > USHRT_MAX || rows == 0 || rows > USHRT_MAX) {
			result = send_error(frame->header.request_id, process->id, "resize-failed", "terminal size was rejected");
		} else {
			memset(&size, 0, sizeof(size)); size.ws_col = (unsigned short)columns; size.ws_row = (unsigned short)rows;
			result = ioctl(process->stdout_fd, TIOCSWINSZ, &size) == 0 ?
			    send_ok(frame->header.request_id, process->id, NULL) :
			    send_error(frame->header.request_id, process->id, "resize-failed", "terminal resize failed");
		}
	} else if (strcmp(operation, "closeStdin") == 0) {
		if (process->stdin_fd >= 0) {
			if (process->config.terminal) { unsigned char eof = 4; (void)write(process->stdin_fd, &eof, 1); }
			else { close(process->stdin_fd); process->stdin_fd = -1; }
		}
		result = send_ok(frame->header.request_id, process->id, NULL);
	} else if (strcmp(operation, "delete") == 0) {
		if (process->started && !process->finalized)
			result = send_error(frame->header.request_id, process->id, "process-running", "running process cannot be deleted");
		else { result = send_ok(frame->header.request_id, process->id, NULL); delete_process(process); }
	} else if (strcmp(operation, "copyIn") == 0) {
		result = handle_copy_in(frame, json, tokens, root);
	} else if (strcmp(operation, "copyOut") == 0) {
		result = handle_copy_out(frame, json, tokens, root);
	} else if (strcmp(operation, "copyList") == 0) {
		result = handle_copy_list(frame, json, tokens, root);
	} else if (strcmp(operation, "ping") == 0) {
		result = send_ok(frame->header.request_id, 0, "\"build\":\"" AGENT_BUILD "\"");
	} else if (strcmp(operation, "shutdown") == 0) {
		result = send_ok(frame->header.request_id, 0, NULL);
		free(operation); free(tokens); free(json);
		sync();
#ifdef __NetBSD__
		reboot(RB_POWERDOWN, NULL);
#endif
		_exit(0);
	} else result = send_error(frame->header.request_id, frame->header.process_id,
	    "unsupported-operation", "operation is not supported by protocol v1");
	free(operation); free(tokens); free(json); return result;
malformed:
	free(operation); free(tokens); free(json);
	return send_error(frame->header.request_id, frame->header.process_id,
	    "malformed-request", "request JSON was rejected");
}

static int
handle_frame(const struct nvza_frame *frame)
{
	struct process *process;
	char event[128];
	ssize_t written;
	if (frame->header.type == NVZA_FRAME_HOST_HELLO) {
		handshake_complete = 1;
		return send_json(NVZA_FRAME_GUEST_READY, frame->header.request_id, 0,
		    "{\"version\":1,\"capabilities\":[\"exec\",\"pty\",\"signals\",\"copy\",\"shutdown\"],\"build\":\"" AGENT_BUILD "\"}");
	}
	if (!handshake_complete)
		return send_error(frame->header.request_id, 0, "handshake-required", "host hello must be the first frame");
	if (frame->header.type == NVZA_FRAME_REQUEST) return handle_request(frame);
	if (frame->header.type == NVZA_FRAME_COPY_DATA) return handle_copy_data(frame);
	if (frame->header.type != NVZA_FRAME_STDIN)
		return send_error(frame->header.request_id, frame->header.process_id, "unexpected-frame", "frame type is invalid in this state");
	process = find_process(frame->header.process_id);
	if (process == NULL || process->stdin_fd < 0)
		return send_error(frame->header.request_id, frame->header.process_id, "stdin-closed", "process stdin is closed");
	written = write(process->stdin_fd, frame->payload, frame->header.payload_length);
	if (written < 0 || (uint32_t)written != frame->header.payload_length)
		return send_error(frame->header.request_id, frame->header.process_id, "stdin-backpressure", "stdin is temporarily unable to accept the frame");
	(void)snprintf(event, sizeof(event),
	    "{\"event\":\"stdinAck\",\"requestID\":%llu}",
	    (unsigned long long)frame->header.request_id);
	return send_json(NVZA_FRAME_EVENT, frame->header.request_id,
	    frame->header.process_id, event);
}

static int
configure_serial(const char *path)
{
	struct termios termios;
	int flags;
	int fd = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK);
	if (fd < 0) return -1;
	if (tcgetattr(fd, &termios) != 0) { close(fd); return -1; }
	cfmakeraw(&termios);
	termios.c_cflag |= CLOCAL | CREAD;
	termios.c_cflag &= ~CRTSCTS;
	if (tcsetattr(fd, TCSAFLUSH, &termios) != 0) { close(fd); return -1; }
	flags = fcntl(fd, F_GETFL);
	if (flags < 0 || fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) != 0) {
		close(fd);
		return -1;
	}
	return fd;
}

int
main(int argc, char **argv)
{
	const char *device = "/dev/ttyVI10";
	struct nvza_decoder decoder;
	struct nvza_frame frame;
	struct kevent change, events[32];
	unsigned char input[65536];
	struct process *process;
	ssize_t count;
	int ready, i, result;

	if (argc == 3 && strcmp(argv[1], "-d") == 0) device = argv[2];
	else if (argc != 1) { fprintf(stderr, "usage: %s [-d device]\n", argv[0]); return 64; }
	(void)signal(SIGPIPE, SIG_IGN);
	fprintf(stderr, "netbsd-vz-agent: opening %s\n", device);
	serial_fd = configure_serial(device);
	if (serial_fd < 0) { log_errno(device); return 1; }
	fprintf(stderr, "netbsd-vz-agent: protocol channel ready\n");
	event_queue = kqueue();
	if (event_queue < 0) { log_errno("kqueue"); return 1; }
	EV_SET(&change, (uintptr_t)serial_fd, EVFILT_READ, EV_ADD | EV_ENABLE, 0, 0, NULL);
	if (kevent(event_queue, &change, 1, NULL, 0, NULL) != 0) { log_errno("watch serial"); return 1; }
	nvza_decoder_init(&decoder);
	for (;;) {
		ready = kevent(event_queue, NULL, 0, events, (int)(sizeof(events) / sizeof(events[0])), NULL);
		if (ready < 0) { if (errno == EINTR) continue; log_errno("kevent"); break; }
		for (i = 0; i < ready; i++) {
			if (events[i].filter == EVFILT_PROC) {
				reap_children();
			} else if ((int)events[i].ident == serial_fd) {
				count = read(serial_fd, input, sizeof(input));
				if (count <= 0) { if (count < 0 && errno == EINTR) continue; goto done; }
				if (nvza_decoder_feed(&decoder, input, (size_t)count) != 0) goto done;
				while ((result = nvza_decoder_next(&decoder, &frame)) == NVZA_CODEC_FRAME) {
					if (handle_frame(&frame) != 0) log_errno("handle frame");
					nvza_frame_destroy(&frame);
				}
				if (result == NVZA_CODEC_ERROR) {
					log_errno("decode protocol frame");
					goto done;
				}
			} else {
				process = events[i].udata;
				if (process != NULL && process->id != 0)
					read_process_output(process, (int)events[i].ident);
			}
		}
		reap_children();
		for (i = 0; i < MAX_PROCESSES; i++)
			if (processes[i].id != 0) finish_process_if_ready(&processes[i]);
	}
done:
	nvza_decoder_destroy(&decoder);
	return 1;
}
