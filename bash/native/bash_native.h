/* The C side of `extern module "bash"` in tree.agc, made by native-gen.
   Do not edit it: change the .agc and make it again. */
#ifndef BASH_NATIVE_H
#define BASH_NATIVE_H

#include "agentica_native.h"

#if AN_API_MAJOR != 1
#error "bash_native.h needs version 1 of the native API (agentica_native.h)"
#endif
#if AN_API_MINOR < 1
#error "bash_native.h needs version 1.1 or later of the native API (agentica_native.h)"
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* A String or Bytes argument, borrowed for the call: copy it to keep it. String data is UTF-8 with no NUL at its
   end. Every header of this version of native-gen has these two, so one file can include several. */
#ifndef NATIVE_GEN_SLICES_1
#define NATIVE_GEN_SLICES_1
typedef struct {
  const char *data;
  size_t len;
} ng_str;
typedef struct {
  const uint8_t *data;
  size_t len;
} ng_buf;
#endif

/* The rows of the type table: the TYPE of an_struct, an_enum and their getters. */
enum { BASH_TYPE_Parsed = 0, BASH_TYPE_Command = 1, BASH_TYPE_Word = 2 };

/* The fields of Parsed, in declared order. */
enum { BASH_Parsed_commands = 0, BASH_Parsed_error = 1 };

/* The fields of Command, in declared order. */
enum { BASH_Command_text = 0, BASH_Command_words = 1 };

/* The fields of Word, in declared order. */
enum { BASH_Word_kind = 0, BASH_Word_text = 1 };

/* The structs and enums as C values. A String or Bytes in them is borrowed, a term lasts for the call: keep them
   in C locals. _get reads a term into OUT; false when it is not one, and then the call has failed with the path of
   the first bad part. A function whose signature does not reach the type reads none ("Point: expected Point").
   _make and the constructors (one per variant) make a term. */

typedef struct {
  an_term commands;
  bool error;
} bash_Parsed;
an_term bash_Parsed_make(an_env *env, const bash_Parsed *value);

typedef struct {
  ng_str text;
  an_term words;
} bash_Command;
an_term bash_Command_make(an_env *env, const bash_Command *value);

typedef struct {
  ng_str kind;
  ng_str text;
} bash_Word;
an_term bash_Word_make(an_env *env, const bash_Word *value);

/* The Lists, Maps, Optionals and Results. A List or Map that is read is a cursor: _next gives 1 for an item, 0 at
   the end, and -1 when the item does not decode: the call has then failed with the path of the item in its own
   List or Map (an item of a List or Map read from another has the path from the inner one, `List[Float].1`),
   after `argument N: ` when the cursor came from an argument (`argument` is then N; it is 0 after _open), and
   every later _next gives -1 too, as after a failed _open. A builder makes one: _begin, then _push (_put for a
   Map), then _end. Cursors and builders hold terms: keep them in C locals, for this call only. An Optional or
   Result that is read is a struct, whose value is zero when there is none and whose error is borrowed as a String
   argument is; _get reads one held as a term. One that is made has _some or _ok (an_none and an_error make the
   others). */

typedef struct {
  an_list_builder builder;
} bash_list_Command_builder;
void bash_list_Command_begin(an_env *env, bash_list_Command_builder *b, size_t hint);
void bash_list_Command_push(an_env *env, bash_list_Command_builder *b, bash_Command value);
an_term bash_list_Command_end(an_env *env, bash_list_Command_builder *b);

typedef struct {
  an_list_builder builder;
} bash_list_Word_builder;
void bash_list_Word_begin(an_env *env, bash_list_Word_builder *b, size_t hint);
void bash_list_Word_push(an_env *env, bash_list_Word_builder *b, bash_Word value);
an_term bash_list_Word_end(an_env *env, bash_list_Word_builder *b);

/* The commands of `line`, read by tree-sitter-bash. */
an_term bash_commands(an_env *env, ng_str line);

#ifdef __cplusplus
}
#endif

#endif

/* Outside the include guard, so a file that included the header before it defined the switch still gets this
   part; its own guard keeps it to one copy. */
#if defined(BASH_NATIVE_IMPLEMENTATION) && !defined(BASH_NATIVE_IMPLEMENTATION_DONE)
#define BASH_NATIVE_IMPLEMENTATION_DONE
/* Declared with C linkage, so a module built as C++ exports it under its C name. */
#ifdef __cplusplus
extern "C" {
#endif
AN_EXPORT const an_module *agentica_native_init(const an_api *api);
#ifdef __cplusplus
}
#endif

an_term bash_Parsed_make(an_env *env, const bash_Parsed *value) {
  an_term fields[2];
  fields[0] = value->commands;
  fields[1] = an_bool(env, value->error);
  return an_struct(env, BASH_TYPE_Parsed, fields);
}

an_term bash_Command_make(an_env *env, const bash_Command *value) {
  an_term fields[2];
  fields[0] = an_string(env, value->text.data, value->text.len);
  fields[1] = value->words;
  return an_struct(env, BASH_TYPE_Command, fields);
}

an_term bash_Word_make(an_env *env, const bash_Word *value) {
  an_term fields[2];
  fields[0] = an_string(env, value->kind.data, value->kind.len);
  fields[1] = an_string(env, value->text.data, value->text.len);
  return an_struct(env, BASH_TYPE_Word, fields);
}

void bash_list_Command_begin(an_env *env, bash_list_Command_builder *b, size_t hint) { an_list_begin(env, &b->builder, hint); }

void bash_list_Command_push(an_env *env, bash_list_Command_builder *b, bash_Command value) {
  an_list_push(env, &b->builder, bash_Command_make(env, &value));
}

an_term bash_list_Command_end(an_env *env, bash_list_Command_builder *b) { return an_list_end(env, &b->builder); }

void bash_list_Word_begin(an_env *env, bash_list_Word_builder *b, size_t hint) { an_list_begin(env, &b->builder, hint); }

void bash_list_Word_push(an_env *env, bash_list_Word_builder *b, bash_Word value) {
  an_list_push(env, &b->builder, bash_Word_make(env, &value));
}

an_term bash_list_Word_end(an_env *env, bash_list_Word_builder *b) { return an_list_end(env, &b->builder); }

static an_term bash_native_commands(an_env *env, int argc, const an_term *argv) {
  (void)argc;
  ng_str a0;
  if (!an_get_string(env, argv[0], &a0.data, &a0.len)) return an_badarg(env, 0);
  return bash_commands(env, a0);
}

static const an_function bash_native_functions[] = {
  {"commands", "(String) -> Parsed", bash_native_commands, AN_SHORT},
};

static const an_type bash_native_types[] = {
  {"Parsed", AN_STRUCT, "commands: List[Command], error: Bool"},
  {"Command", AN_STRUCT, "text: String, words: List[Word]"},
  {"Word", AN_STRUCT, "kind: String, text: String"},
};

/* Ends the module's one .c file: the tables and agentica_native_init. LOAD is NULL or a const char *(*)(void)
   that runs once at the first call, and refuses the module with the message it returns. */
#define BASH_NATIVE_MODULE(LOAD) AN_MODULE_TABLES("bash", bash_native_functions, 1, bash_native_types, 3, NULL, 0, LOAD)
#endif
