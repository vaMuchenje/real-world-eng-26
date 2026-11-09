"""Single-use trusted worker with fixed operations and bounded JSON transport."""

from __future__ import annotations

import ctypes
import ctypes.util
import errno
import json
import os
import resource
import socket
import sys
from pathlib import Path
from typing import Any

# Python -I removes the script directory: add only this trusted image directory.
SERVICE_DIRECTORY = Path(__file__).resolve().parent
sys.path.insert(0, str(SERVICE_DIRECTORY))

import backend  # noqa: E402
import runtime  # noqa: E402


def _deny_network_sockets() -> None:
    """Allow Unix IPC only in training/blend workers; fail closed without seccomp."""
    library = ctypes.util.find_library("seccomp")
    if library is None:
        raise RuntimeError("libseccomp is required for trusted compute workers")
    seccomp = ctypes.CDLL(library, use_errno=True)
    seccomp.seccomp_init.argtypes = [ctypes.c_uint32]
    seccomp.seccomp_init.restype = ctypes.c_void_p
    seccomp.seccomp_release.argtypes = [ctypes.c_void_p]
    seccomp.seccomp_load.argtypes = [ctypes.c_void_p]
    seccomp.seccomp_load.restype = ctypes.c_int
    seccomp.seccomp_syscall_resolve_name.argtypes = [ctypes.c_char_p]
    seccomp.seccomp_syscall_resolve_name.restype = ctypes.c_int
    # seccomp_rule_add has a variadic trailing struct argument.
    seccomp.seccomp_rule_add.argtypes = [
        ctypes.c_void_p,
        ctypes.c_uint32,
        ctypes.c_int,
        ctypes.c_uint,
    ]
    seccomp.seccomp_rule_add.restype = ctypes.c_int

    class Comparison(ctypes.Structure):
        _fields_ = [
            ("arg", ctypes.c_uint),
            ("op", ctypes.c_int),
            ("a", ctypes.c_uint64),
            ("b", ctypes.c_uint64),
        ]

    context = seccomp.seccomp_init(0x7FFF0000)  # SCMP_ACT_ALLOW
    if not context:
        raise RuntimeError("could not initialize worker syscall policy")
    try:
        for name in (b"socket", b"socketpair"):
            syscall = seccomp.seccomp_syscall_resolve_name(name)
            if (
                syscall < 0
                or seccomp.seccomp_rule_add(
                    context,
                    0x00050000 | errno.EPERM,
                    syscall,
                    1,
                    Comparison(0, 1, socket.AF_UNIX, 0),
                )
                != 0
            ):
                raise RuntimeError("could not configure worker syscall policy")
        if seccomp.seccomp_load(context) != 0:
            raise RuntimeError("could not activate worker syscall policy")
    finally:
        seccomp.seccomp_release(context)


def _limits(operation: str, *, reusable: bool = False) -> None:
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    resource.setrlimit(resource.RLIMIT_NOFILE, (4096, 4096))
    resource.setrlimit(resource.RLIMIT_FSIZE, (2_100_000_000, 2_100_000_000))
    wall_seconds = (
        backend.BLEND_TIMEOUT_SECONDS
        if operation == "blend_checkpoints"
        else backend.GPU_TIMEOUT_SECONDS
    )
    cpu_seconds = 8 * (26 * 60 * 60 if reusable else wall_seconds)
    resource.setrlimit(resource.RLIMIT_CPU, (cpu_seconds, cpu_seconds))
    if operation == "blend_checkpoints":
        resource.setrlimit(resource.RLIMIT_AS, (16 * 1024**3, 16 * 1024**3))
    if operation not in {"sample", "sample_batch"}:
        _deny_network_sockets()
    # vLLM uses loopback TCP for local multiprocessing. Sampling runs solely
    # fixed trusted code, with offline local model paths and telemetry disabled.
    # Its GPU/host memory is bounded by the service container, not RLIMIT_AS:
    # CUDA reserves large virtual-address ranges beyond physical memory.


def _dispatch(document: object) -> Any:
    if not isinstance(document, dict) or set(document) != {"operation", "args"}:
        raise ValueError("worker request shape is invalid")
    operation, args = document["operation"], document["args"]
    if (
        not isinstance(operation, str)
        or operation not in backend.WORKER_OPERATIONS
        or not isinstance(args, list)
    ):
        raise ValueError("worker operation is invalid")
    _limits(operation)
    if operation in {"sample", "sample_batch"}:
        if len(args) != 2:
            raise ValueError("sampling worker arguments are invalid")
        binding, payload = args
        if binding is None:
            instance = runtime.BaseRuntime()
        else:
            if not isinstance(binding, dict) or set(binding) != {
                "checkpoint_id",
                "checkpoint_digest",
                "trial_id",
            }:
                raise ValueError("sampling binding is invalid")
            instance = runtime.CheckpointRuntime(**binding)
        instance.load()
        return getattr(instance, operation)(payload)
    if len(args) != 1:
        raise ValueError("mutation worker arguments are invalid")
    return getattr(runtime, operation)(args[0])


def serve_sampler() -> int:
    """Load one immutable binding once and serve sequential bounded requests."""
    # Native libraries also write to fd 1. Preserve a dedicated protocol descriptor,
    # then route all normal stdout to the discarded diagnostic stream.
    protocol_fd = os.dup(sys.stdout.fileno())
    os.set_inheritable(protocol_fd, False)
    os.dup2(sys.stderr.fileno(), sys.stdout.fileno())
    instance = None
    binding_key = None
    expected_sequence = 1
    with os.fdopen(protocol_fd, "wb") as protocol:
        _limits("sample", reusable=True)
        while True:
            raw = sys.stdin.buffer.readline(backend.MAX_WORKER_JSON_BYTES + 2)
            if not raw:
                return 0
            sequence = expected_sequence
            try:
                if not raw.endswith(b"\n") or len(raw) > backend.MAX_WORKER_JSON_BYTES + 1:
                    raise ValueError("sampling request exceeds its framing or byte bound")
                document = json.loads(raw)
                backend._encode(document)
                if not isinstance(document, dict) or set(document) != {
                    "operation",
                    "args",
                    "sequence",
                }:
                    raise ValueError("sampling request shape is invalid")
                sequence = document["sequence"]
                if type(sequence) is not int or sequence != expected_sequence:
                    raise ValueError("sampling request sequence mismatch")
                operation, args = document["operation"], document["args"]
                if (
                    operation not in {"sample", "sample_batch"}
                    or not isinstance(args, list)
                    or len(args) != 2
                ):
                    raise ValueError("sampling operation or arguments are invalid")
                binding, payload = args
                key = backend._encode(binding)
                if instance is None:
                    if binding is None:
                        instance = runtime.BaseRuntime()
                    else:
                        if not isinstance(binding, dict) or set(binding) != {
                            "checkpoint_id",
                            "checkpoint_digest",
                            "trial_id",
                        }:
                            raise ValueError("sampling binding is invalid")
                        instance = runtime.CheckpointRuntime(**binding)
                    binding_key = key
                    instance.load()
                elif key != binding_key:
                    raise ValueError("sampling worker cannot change checkpoint binding")
                result = getattr(instance, operation)(payload)
                encoded = backend._encode({"sequence": sequence, "ok": True, "result": result})
                expected_sequence += 1
            except Exception as exc:
                encoded = backend._encode(
                    {
                        "sequence": sequence,
                        "ok": False,
                        "error_type": type(exc).__name__,
                        "error": str(exc)[:4000],
                    }
                )
                protocol.write(encoded + b"\n")
                protocol.flush()
                return 1
            protocol.write(encoded + b"\n")
            protocol.flush()


def main() -> int:
    if sys.argv[1:] == ["--sampler"]:
        return serve_sampler()
    if len(sys.argv) != 3:
        return 2
    request, response = map(Path, sys.argv[1:])
    try:
        document = backend._read_result(request)
        result = {"ok": True, "result": _dispatch(document)}
        payload = backend._encode(result)
        code = 0
    except Exception as exc:
        payload = backend._encode(
            {"ok": False, "error_type": type(exc).__name__, "error": str(exc)[:4000]}
        )
        code = 1
    descriptor = os.open(response, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "wb") as stream:
        stream.write(payload)
        stream.flush()
        os.fsync(stream.fileno())
    return code


if __name__ == "__main__":
    raise SystemExit(main())
