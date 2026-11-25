## For tests, here and in the users of this package: a stand-in for `monty subprocess` that replays a fixture of
## recorded frames. For each request it reads, it checks that the request is the recorded one (else a FatalError;
## a recorded `*` takes any request) and writes the recorded replies (a reply `raw:HEX` goes out unframed). Past the
## recorded requests it answers nothing. With `MONTY_RECORD` set to a real worker it relays to it and writes the
## fixture instead. A test program's `main` calls `serve_fake(fixture)`; `--silent` answers nothing at all.

import Binary from "std/binary"

struct Recording
  requests: List[String]
  replies: List[List[String]]
end

def serve_fake(fixture: String) -> Void
  if fixture == "--silent"
    Task.sleep(600_000)
    return
  end

  out = File.open("/dev/stdout", "append").unwrap!
  case System.env("MONTY_RECORD")
    ok(real) if real != "" -> record(real, fixture, out)
    _ -> replay(JSON.decode(File.read_text(fixture).unwrap!, Recording).unwrap!, out)
  end
end

private

def replay(recording: Recording, out: File.Handle) -> Void
  index = 0
  while true
    request = read_frame().unwrap_or("".bytes)
    break if request.empty?

    if index >= recording.requests.size
      Task.sleep(600_000)
      break
    end

    if recording.requests[index] != "*" and hex(request) != recording.requests[index]
      write(out, fatal("request #{index} is not the recorded one: #{hex(request)}"))
      break
    end

    for reply in recording.replies[index]
      if reply.start_with?("raw:")
        File.write_bytes(out, unhex(reply.slice(4, reply.length - 4))).unwrap!
        File.flush(out).unwrap!
      else
        write(out, unhex(reply))
      end
    end

    index = index + 1
  end
end

def record(real: String, fixture: String, out: File.Handle) -> Void
  worker = Process.spawn_captured(real, ["subprocess"]).unwrap!
  requests: List[String] = []
  replies: List[List[String]] = []
  while true
    request = read_frame().unwrap_or("".bytes)
    break if request.empty?

    send(worker, request)
    requests = requests.push(hex(request))
    group: List[Bytes] = []
    while true
      reply = worker_frame(worker)
      break if reply.empty?

      group = group.push(reply)
      break if not print?(reply)
    end

    # Written before the replies go out: the client stops this process once it has its answer.
    replies = replies.push(group.map { |reply| hex(reply) })
    File.write_text(fixture, JSON.encode(Recording(requests: requests, replies: replies))).unwrap!
    for reply in group
      write(out, reply)
    end
  end
end

# A Print event (field 1 of WorkerEvent) does not end the worker's answer.
def print?(frame: Bytes) -> Bool = frame.length > 0 and frame.at(0) == 10

def read_frame() -> Result[Bytes]
  head = try IO.read_bytes(4)
  return ok("".bytes) if head.length < 4

  IO.read_bytes((try Binary.read_u32_le(head, 0)).to_i)
end

def worker_frame(worker: Process) -> Bytes
  head = Process.read_bytes(worker, 4, 30_000).unwrap_or("".bytes)
  return "".bytes if head.length < 4

  Process.read_bytes(worker, Binary.read_u32_le(head, 0).unwrap!.to_i, 30_000).unwrap_or("".bytes)
end

def send(worker: Process, frame: Bytes) -> Void
  Process.send_bytes(worker, Bytes.concat([Binary.write_u32_le(frame.length.to_uint32!), frame]), 30_000).unwrap!
end

def write(out: File.Handle, frame: Bytes) -> Void
  File.write_bytes(out, Bytes.concat([Binary.write_u32_le(frame.length.to_uint32!), frame])).unwrap!
  File.flush(out).unwrap!
end

# WorkerEvent.fatal_error (11) with its message (1).
def fatal(message: String) -> Bytes
  text = message.slice(0, 100).bytes
  inner = Bytes.concat([Bytes.from_list([10, text.length]).unwrap!, text])
  Bytes.concat([Bytes.from_list([90, inner.length]).unwrap!, inner])
end

def hex(data: Bytes) -> String = OpenSSL.Digest.hexencode(data)

def unhex(text: String) -> Bytes
  Bytes.from_list(
    (0...(text.length / 2)).map { |i| digit(text.slice(2 * i, 1)) * 16 + digit(text.slice(2 * i + 1, 1)) },
  ).unwrap!
end

def digit(char: String) -> Int = "0123456789abcdef".index_of(char).unwrap!
