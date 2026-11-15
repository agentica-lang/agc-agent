## Server-Sent Events: a parser for clients and a writer for servers. Pure: no I/O.
##
## The parser is strict about UTF-8: a line that is not UTF-8 is an error, where the WHATWG parser would replace the
## bad bytes. The LLM APIs and our server send UTF-8, so bad bytes mean a broken stream, and an error is safer than
## text that changed in silence. `retry:` is read and ignored: no client reconnects by itself yet.

import Reader from "src/reader"
import Writer from "src/writer"

VERSION = "0.0.1"

export Reader.Event
export Reader.Parser
export Reader.Fed
export Reader.parser
export Reader.feed
export Writer.encode
