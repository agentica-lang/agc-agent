## An error on the wire: the body of a failed request and the data of the `error` event.

import Wire from "wire"

struct Failure
  ## A dotted name to branch on (`session.busy`), never the message.
  kind: String
  message: String
end

def encode_failure(failure: Failure) -> String = JSON.encode(failure)

def decode_failure(text: String) -> Result[Failure] = Wire.decode(text, Failure.codec)
