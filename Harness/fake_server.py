"""Starts a REAL Jarvis gateway on a spare local port, with a throwaway data directory and the project's own
fakes (scripted LLM, fake speech-to-text and text-to-speech). Nothing here touches the owner's data, the live
server on port 8000, or any paid provider.

Usage (see run_harness.sh, which scrubs the environment first):
    python -I fake_server.py <project-jarvis-dir> <workdir>

Prints, one per line, when ready:
    PORT <n>
    CODE <one-time pairing code>
and, when stdin closes, prints one STT summary line and exits.
Reads project-jarvis' code (server/ and tests/ helpers); writes only under <workdir>.
"""
from __future__ import annotations

import sys
import threading
from pathlib import Path


def main() -> None:
    root = Path(sys.argv[1]).resolve()
    work = Path(sys.argv[2]).resolve()
    work.mkdir(parents=True, exist_ok=True)
    sys.path[:0] = [str(root / "server"), str(root)]

    import asyncio

    from tests.fake_voice import VoiceRig
    from tests.fakes import FakeLLM, say
    from tests.live_server import run_server

    # plenty of scripted replies: the greeting turn on connect, then one per message
    steps = [say(f"Fake reply {i}. All systems nominal.") for i in range(40)]
    rig = VoiceRig(chunks=3)
    with run_server(work, FakeLLM(*steps), voice_factory=rig.factory) as live:
        def new_code() -> str:
            return asyncio.run(live.code())

        print(f"PORT {live.runtime_port}", flush=True)
        print(f"CODE {new_code()}", flush=True)
        for _ in sys.stdin:  # runs until the harness closes stdin
            pass
        print(f"STT opened={rig.stt.opened} real_frames={len(rig.stt.frames)} silent_frames={rig.stt.silence_frames}", flush=True)


if __name__ == "__main__":
    threading.current_thread().name = "fake-server-main"
    main()
