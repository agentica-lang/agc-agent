/* The commands of a bash line, read by tree-sitter-bash, for `commands` of src/tree.agc. Every decision on them is
   made in Agentica. */
#define BASH_NATIVE_IMPLEMENTATION
#include "bash_native.h"

#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#else
#include <time.h>
#endif

#include "runtime/tree_sitter/api.h"

const TSLanguage *tree_sitter_bash(void);

/* The most text the commands of a line may hold: a substitution's text is in the command around it too, so deep
   nesting would make a result quadratic in the line. */
#define MAX_TEXT ((size_t)1 << 20)

typedef struct {
  ng_str line;
  bool unclear;
  size_t text;
} reading;

static ng_str counted(reading *r, ng_str text) {
  r->text += text.len;
  return text;
}

static bool is(TSNode node, const char *type) { return strcmp(ts_node_type(node), type) == 0; }

static bool field_is(const char *field, const char *name) { return field != NULL && strcmp(field, name) == 0; }

static bool blank(char c) { return c == ' ' || c == '\t' || c == '\n' || c == '\r'; }

static ng_str slice(ng_str line, TSNode node) {
  uint32_t start = ts_node_start_byte(node);
  uint32_t end = ts_node_end_byte(node);
  while (start < end && blank(line.data[start])) start++;
  while (end > start && blank(line.data[end - 1])) end--;
  return (ng_str){line.data + start, end - start};
}

static bool has_backtick(ng_str line, TSNode node) {
  uint32_t start = ts_node_start_byte(node);
  return memchr(line.data + start, '`', ts_node_end_byte(node) - start) != NULL;
}

/* Whether a word has a backtick that is not the edge of a command substitution: a token of its own, outside the
   substitutions in it (whose commands are read as commands) and its single-quoted strings. */
static bool stray_backtick(ng_str line, TSNode word) {
  if (is(word, "command_substitution") || !has_backtick(line, word)) return false;
  TSTreeCursor cursor = ts_tree_cursor_new(word);
  bool found = false;
  bool done = false;
  while (!done && !found) {
    TSNode node = ts_tree_cursor_current_node(&cursor);
    bool skip = is(node, "command_substitution") || is(node, "raw_string") || is(node, "ansi_c_string");
    if (!skip && ts_node_child_count(node) == 0 && has_backtick(line, node)) found = true;
    if (!skip && ts_tree_cursor_goto_first_child(&cursor)) continue;
    while (!ts_tree_cursor_goto_next_sibling(&cursor)) {
      if (!ts_tree_cursor_goto_parent(&cursor)) {
        done = true;
        break;
      }
    }
  }
  ts_tree_cursor_delete(&cursor);
  return found;
}

/* The text between two nodes, or a node's edge and a child, inside `parent`: blanks only, where tree-sitter-bash
   read what bash reads. Else the line is unclear: a token it dropped (`a - 2>x` loses `-`), a line end inside a
   command (`a | b | c x` and a line end then `d <<EOF` give one command `c x d`), or a line continuation inside a
   word (`a\` and a line end then `b` is the word `ab` to bash, two words to it). A here-document body is text. */
static void gap(reading *r, TSNode parent, uint32_t from, uint32_t to) {
  if (from >= to || is(parent, "heredoc_body")) return;
  bool command = is(parent, "command") || is(parent, "declaration_command") || is(parent, "unset_command");
  const char *s = r->line.data;
  for (uint32_t i = from; i < to; i++) {
    if (s[i] == ' ' || s[i] == '\t' || s[i] == '\r' || (s[i] == '\n' && !command)) continue;
    if (s[i] == '\\' && i + 1 < to && s[i + 1] == '\n') {
      if (i > 0 && !blank(s[i - 1]) && i + 2 < r->line.len && !blank(s[i + 2])) r->unclear = true;
      i++;
      continue;
    }
    r->unclear = true;
    return;
  }
}

/* A word of a command; with no builder (`b` NULL) only checked, for a statement that has no words. */
static void push_word(an_env *env, reading *r, bash_list_Word_builder *b, TSNode node) {
  if (stray_backtick(r->line, node)) r->unclear = true;
  if (b == NULL) return;
  bash_Word word = {{ts_node_type(node), strlen(ts_node_type(node))}, counted(r, slice(r->line, node))};
  bash_list_Word_push(env, b, word);
}

/* The words a redirection gives its command: the destinations of `>` after the first (`cmd >out x`), the arguments
   after a here-document's start (`cat <<EOF x`), with those of a redirection it holds (`git <<EOF 2>x push`), and
   those after a here-string's word (`cat <<< w x`); how many. Its first destination, not a word, is checked for a
   stray backtick too. */
static int redirect_words(an_env *env, reading *r, bash_list_Word_builder *b, TSNode redirect) {
  bool file = is(redirect, "file_redirect");
  bool here = is(redirect, "heredoc_redirect");
  bool string = is(redirect, "herestring_redirect");
  if (!file && !here && !string) return 0;
  TSTreeCursor cursor = ts_tree_cursor_new(redirect);
  int destinations = 0;
  int named = 0;
  int count = 0;
  if (ts_tree_cursor_goto_first_child(&cursor)) {
    do {
      TSNode child = ts_tree_cursor_current_node(&cursor);
      const char *field = ts_tree_cursor_current_field_name(&cursor);
      bool word = (file && field_is(field, "destination") && destinations++ > 0) ||
                  (here && field_is(field, "argument")) || (string && ts_node_is_named(child) && named++ > 0);
      if (word) {
        push_word(env, r, b, child);
        count++;
      } else if (stray_backtick(r->line, child)) {
        r->unclear = true;
      }
      if (here && field_is(field, "redirect")) count += redirect_words(env, r, b, child);
    } while (ts_tree_cursor_goto_next_sibling(&cursor));
  }
  ts_tree_cursor_delete(&cursor);
  return count;
}

/* The words of the redirections of a statement (`statement`, a null node when there is none); how many. */
static int statement_words(an_env *env, reading *r, bash_list_Word_builder *b, TSNode statement) {
  if (ts_node_is_null(statement)) return 0;
  int count = 0;
  TSTreeCursor cursor = ts_tree_cursor_new(statement);
  if (ts_tree_cursor_goto_first_child(&cursor)) {
    do {
      if (field_is(ts_tree_cursor_current_field_name(&cursor), "redirect"))
        count += redirect_words(env, r, b, ts_tree_cursor_current_node(&cursor));
    } while (ts_tree_cursor_goto_next_sibling(&cursor));
  }
  ts_tree_cursor_delete(&cursor);
  return count;
}

/* The name and arguments of a command in source order, with those of its redirections and of the redirections of
   its statement (`statement`, a null node when it has none). */
static an_term command_words(an_env *env, reading *r, TSNode command, TSNode statement) {
  bash_list_Word_builder b;
  bash_list_Word_begin(env, &b, 0);
  TSTreeCursor cursor = ts_tree_cursor_new(command);
  if (ts_tree_cursor_goto_first_child(&cursor)) {
    do {
      TSNode child = ts_tree_cursor_current_node(&cursor);
      const char *field = ts_tree_cursor_current_field_name(&cursor);
      if (field_is(field, "name") || field_is(field, "argument")) push_word(env, r, &b, child);
      else redirect_words(env, r, &b, child);
    } while (ts_tree_cursor_goto_next_sibling(&cursor));
  }
  ts_tree_cursor_delete(&cursor);
  statement_words(env, r, &b, statement);
  return bash_list_Word_end(env, &b);
}

/* A statement that runs no program by name but may act (`export`, `unset`, `[[ ]]`, a bare `x=1`). `parent` is the
   enclosing node, null at the top. */
static bool other_statement(TSNode node, TSNode parent) {
  if (is(node, "declaration_command") || is(node, "unset_command") || is(node, "test_command")) return true;
  if (!is(node, "variable_assignment") && !is(node, "variable_assignments")) return false;
  return ts_node_is_null(parent) ||
         !(is(parent, "command") || is(parent, "declaration_command") || is(parent, "variable_assignments"));
}

/* The one word of such a statement: its node type and its text. Words its redirections carry (`V=1 <<EOF rm x`) run
   as a command to bash: the line is then unclear. */
static an_term single_word(an_env *env, reading *r, TSNode node, TSNode statement) {
  if (statement_words(env, r, NULL, statement) > 0) r->unclear = true;
  bash_list_Word_builder b;
  bash_list_Word_begin(env, &b, 1);
  bash_Word word = {{ts_node_type(node), strlen(ts_node_type(node))}, counted(r, slice(r->line, node))};
  bash_list_Word_push(env, &b, word);
  return bash_list_Word_end(env, &b);
}

/* The nodes from the root to the cursor's, so a node's parent is known without ts_node_parent (which walks down from
   the root each time). */
typedef struct {
  TSNode *nodes;
  /* How many backtick substitutions are among nodes[0..i]. */
  uint32_t *ticks;
  size_t len;
  size_t cap;
} path;

static bool backtick_substitution(ng_str line, TSNode node) {
  return is(node, "command_substitution") && line.data[ts_node_start_byte(node)] == '`';
}

/* Sets the node at `p->len - 1`, after the node above it. */
static void path_set(path *p, ng_str line, TSNode node) {
  size_t i = p->len - 1;
  p->nodes[i] = node;
  p->ticks[i] = (i > 0 ? p->ticks[i - 1] : 0) + (backtick_substitution(line, node) ? 1 : 0);
}

static bool path_push(path *p, ng_str line, TSNode node) {
  if (p->len == p->cap) {
    size_t cap = p->cap == 0 ? 64 : p->cap * 2;
    TSNode *nodes = realloc(p->nodes, cap * sizeof(TSNode));
    if (nodes != NULL) p->nodes = nodes;
    uint32_t *ticks = realloc(p->ticks, cap * sizeof(uint32_t));
    if (ticks != NULL) p->ticks = ticks;
    if (nodes == NULL || ticks == NULL) return false;
    p->cap = cap;
  }
  p->len++;
  path_set(p, line, node);
  return true;
}

/* The redirected statement whose redirections belong to the node at the end of `p`: the one whose body it is, or
   whose body ends with it (tree-sitter-bash puts the redirections of the last command of a pipeline, a list or a
   `!` on the whole of it: `a | b 2>x y`). A null node when there is none. */
static TSNode statement_of(const path *p) {
  TSNode node = p->nodes[p->len - 1];
  uint32_t end = ts_node_end_byte(node);
  for (size_t i = p->len - 1; i > 0; i--) {
    TSNode up = p->nodes[i - 1];
    if (is(up, "redirected_statement")) {
      return ts_node_eq(ts_node_child_by_field_name(up, "body", 4), p->nodes[i]) ? up : (TSNode){0};
    }
    if (ts_node_end_byte(up) != end || !(is(up, "pipeline") || is(up, "list") || is(up, "negated_command"))) break;
  }
  return (TSNode){0};
}

/* A monotonic clock in milliseconds. On Windows not clock_gettime: MinGW takes it from libwinpthread, a DLL that the
   loader does not find beside a prebuilt library; and not GetTickCount64, which moves in steps of 15.6 ms. */
static int64_t now_ms(void) {
#ifdef _WIN32
  LARGE_INTEGER frequency, count;
  QueryPerformanceFrequency(&frequency);
  QueryPerformanceCounter(&count);
  return (int64_t)(count.QuadPart / frequency.QuadPart) * 1000 +
         (int64_t)(count.QuadPart % frequency.QuadPart) * 1000 / frequency.QuadPart;
#else
  struct timespec now;
  clock_gettime(CLOCK_MONOTONIC, &now);
  return (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;
#endif
}

static bool cancel(TSParseState *state) {
  const int64_t *deadline = state->payload;
  return now_ms() >= *deadline;
}

static const char *read_line(void *payload, uint32_t byte, TSPoint point, uint32_t *read) {
  (void)point;
  const ng_str *line = payload;
  if (byte >= line->len) {
    *read = 0;
    return "";
  }
  *read = (uint32_t)(line->len - byte);
  return line->data + byte;
}

static an_term failed(an_env *env, const char *message) { return an_error(env, message, strlen(message)); }

an_term bash_commands(an_env *env, ng_str line, int64_t limit_ms) {
  if (line.len > UINT32_MAX) return failed(env, "the line is too long");
  if (limit_ms < 1 || limit_ms > 60000) return failed(env, "the limit must be from 1 to 60000 ms");
  TSParser *parser = ts_parser_new();
  if (!ts_parser_set_language(parser, tree_sitter_bash())) {
    ts_parser_delete(parser);
    return failed(env, "tree-sitter-bash does not load");
  }
  int64_t deadline = now_ms() + limit_ms;
  TSInput input = {&line, read_line, TSInputEncodingUTF8, NULL};
  TSParseOptions options = {&deadline, cancel};
  TSTree *tree = ts_parser_parse_with_options(parser, NULL, input, options);
  ts_parser_delete(parser);
  if (tree == NULL) return failed(env, "the parse took too long");

  TSNode root = ts_tree_root_node(tree);
  reading r = {line, false, 0};
  path p = {NULL, NULL, 0, 0};
  bool walking = path_push(&p, line, root);
  bash_list_Command_builder b;
  bash_list_Command_begin(env, &b, 0);
  TSTreeCursor cursor = ts_tree_cursor_new(root);
  while (walking && r.text <= MAX_TEXT) {
    TSNode node = p.nodes[p.len - 1];
    TSNode parent = p.len > 1 ? p.nodes[p.len - 2] : (TSNode){0};
    if (is(node, "command") || other_statement(node, parent)) {
      TSNode statement = statement_of(&p);
      bool whole = !ts_node_is_null(statement) && ts_node_eq(statement, parent);
      ng_str text = counted(&r, slice(line, whole ? parent : node));
      an_term words =
          is(node, "command") ? command_words(env, &r, node, statement) : single_word(env, &r, node, statement);
      bash_Command command = {text, words};
      bash_list_Command_push(env, &b, command);
    } else if (is(node, "heredoc_body") && has_backtick(line, node)) {
      r.unclear = true;
    }
    /* Backticks do not nest unescaped: bash ends the outer substitution at the inner one's first backtick. */
    if (p.ticks[p.len - 1] > 1) r.unclear = true;

    if (ts_tree_cursor_goto_first_child(&cursor)) {
      TSNode child = ts_tree_cursor_current_node(&cursor);
      gap(&r, node, ts_node_start_byte(node), ts_node_start_byte(child));
      walking = path_push(&p, line, child);
      continue;
    }
    uint32_t end = ts_node_end_byte(node);
    while (walking && !ts_tree_cursor_goto_next_sibling(&cursor)) {
      if (p.len > 1) gap(&r, p.nodes[p.len - 2], end, ts_node_end_byte(p.nodes[p.len - 2]));
      walking = ts_tree_cursor_goto_parent(&cursor);
      p.len--;
      if (p.len > 0) end = ts_node_end_byte(p.nodes[p.len - 1]);
    }
    if (walking) {
      TSNode next = ts_tree_cursor_current_node(&cursor);
      gap(&r, p.nodes[p.len - 2], end, ts_node_start_byte(next));
      path_set(&p, line, next);
    }
  }
  bool complete = p.len == 0;
  ts_tree_cursor_delete(&cursor);
  free(p.nodes);
  free(p.ticks);

  an_term commands = bash_list_Command_end(env, &b);
  bool error = ts_node_has_error(root);
  ts_tree_delete(tree);
  if (r.text > MAX_TEXT) return failed(env, "the commands of the line hold over 1 MiB of text");
  if (!complete) return failed(env, "out of memory");
  bash_Parsed parsed = {commands, error, r.unclear};
  return bash_result_Parsed_ok(env, parsed);
}

BASH_NATIVE_MODULE(NULL)
