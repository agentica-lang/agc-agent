// The parser of tree-sitter-bash (src/parser.c, 9.5 MB) is vendored outside the package, in vendor/tree-sitter-bash/:
// a fetched package holds no file over 1 MiB, so a fetched bash downloads its library ([native.bash.prebuilt] of
// agentica.toml), and this include is found only in a checkout of the repository. The sha256 of that parser, which
// `make native-check` checks, puts it in the source key of the module, which names the downloaded libraries.
// sha256 5ad30bb1a260c76df5397490b8bd97e272e62ed9c99be36fa53da959d7667e7f
#include "../../../vendor/tree-sitter-bash/parser.c"
