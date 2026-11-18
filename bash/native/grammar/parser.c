// The parser of tree-sitter-bash (src/parser.c, 9.5 MB) is the one of the submodule vendor/tree-sitter-bash, outside
// the package: a fetched package holds no file over 1 MiB. A checkout builds it through this include (`make install`
// fetches the submodule); a fetched bash cannot, and uses a prebuilt library instead. The sha256 of that parser, which
// `make native-check` checks, puts it in the source key of the module.
// sha256 5ad30bb1a260c76df5397490b8bd97e272e62ed9c99be36fa53da959d7667e7f
#include "../../../vendor/tree-sitter-bash/src/parser.c"
