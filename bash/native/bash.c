/* The native module of native.agc: the simple commands of a bash line, read by tree-sitter-bash. Every decision on
   them is made in Agentica. */
#define BASH_NATIVE_IMPLEMENTATION
#include "bash_native.h"

#include <string.h>

#include "runtime/tree_sitter/api.h"

const TSLanguage *tree_sitter_bash(void);

static bool is(TSNode node, const char *type) { return strcmp(ts_node_type(node), type) == 0; }

static bool blank(char c) { return c == ' ' || c == '\t' || c == '\n' || c == '\r'; }

static ng_str slice(ng_str line, TSNode node) {
  uint32_t start = ts_node_start_byte(node);
  uint32_t end = ts_node_end_byte(node);
  while (start < end && blank(line.data[start])) start++;
  while (end > start && blank(line.data[end - 1])) end--;
  return (ng_str){line.data + start, end - start};
}

static ng_str text(const char *s) { return (ng_str){s, strlen(s)}; }

/* The name and arguments of a command: its children in the fields `name` and `argument`. */
static an_term words(an_env *env, ng_str line, TSNode command) {
  bash_list_Word_builder b;
  uint32_t count = ts_node_child_count(command);
  bash_list_Word_begin(env, &b, count);
  for (uint32_t i = 0; i < count; i++) {
    const char *field = ts_node_field_name_for_child(command, i);
    if (field == NULL || (strcmp(field, "name") != 0 && strcmp(field, "argument") != 0)) continue;
    TSNode child = ts_node_child(command, i);
    bash_Word word = {text(ts_node_type(child)), slice(line, child)};
    bash_list_Word_push(env, &b, word);
  }
  return bash_list_Word_end(env, &b);
}

/* The text of a command: that of its redirected statement, when it has one. */
static TSNode statement(TSNode command) {
  TSNode parent = ts_node_parent(command);
  return !ts_node_is_null(parent) && is(parent, "redirected_statement") ? parent : command;
}

an_term bash_commands(an_env *env, ng_str line) {
  if (line.len > UINT32_MAX) return an_raise(env, "the line is too long");
  TSParser *parser = ts_parser_new();
  if (!ts_parser_set_language(parser, tree_sitter_bash())) {
    ts_parser_delete(parser);
    return an_raise(env, "tree-sitter-bash does not load");
  }
  TSTree *tree = ts_parser_parse_string(parser, NULL, line.data, (uint32_t)line.len);
  ts_parser_delete(parser);
  if (tree == NULL) return an_raise(env, "tree-sitter-bash did not parse the line");

  TSNode root = ts_tree_root_node(tree);
  bash_list_Command_builder b;
  bash_list_Command_begin(env, &b, 0);
  TSTreeCursor cursor = ts_tree_cursor_new(root);
  bool done = false;
  while (!done) {
    TSNode node = ts_tree_cursor_current_node(&cursor);
    if (is(node, "command")) {
      bash_Command command = {slice(line, statement(node)), words(env, line, node)};
      bash_list_Command_push(env, &b, command);
    }
    if (ts_tree_cursor_goto_first_child(&cursor)) continue;
    while (!ts_tree_cursor_goto_next_sibling(&cursor)) {
      if (!ts_tree_cursor_goto_parent(&cursor)) {
        done = true;
        break;
      }
    }
  }
  ts_tree_cursor_delete(&cursor);

  bash_Parsed parsed = {bash_list_Command_end(env, &b), ts_node_has_error(root)};
  ts_tree_delete(tree);
  return bash_Parsed_make(env, &parsed);
}

BASH_NATIVE_MODULE(NULL)
