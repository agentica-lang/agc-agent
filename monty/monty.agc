## Runs Python scripts in pydantic's Monty sandbox: its own worker, `monty subprocess`, driven over stdio with the
## protobuf of `monty.proto` (monty.v1, protocol 8). The script calls host functions by name with keyword arguments;
## each call suspends the script until the host answers. The worker has no file system, network or environment: every
## OS call gets its no-handler default. Limits: memory, recursion, sandbox time, the number of calls, and a wall-clock
## wait for each answer of the worker.

import Install from "src/install"
import Worker from "src/worker"

VERSION = "0.0.1"
## The pinned Monty release: the worker binary and the codec go together.
MONTY_VERSION = Install.MONTY_VERSION

export Worker.Limits
export Worker.Call
export Worker.Answer
export Worker.Outcome
export Worker.run
export Worker.command
export Install.Wheel
export Install.wheel
export Install.platform
export Install.binary
