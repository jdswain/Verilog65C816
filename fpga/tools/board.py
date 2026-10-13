#!/usr/bin/env python3
"""Talk to the 65C816 SoC on the Tang Nano 20K.

    board.py boot  <bitstream.fs> [s]  program, capturing output (default 3 s)
    board.py send  "dm e000"          type a line at the monitor, print reply
    board.py read  [seconds]          just listen
    board.py load  <bitstream.fs> <image.fb>
                                      program the imgload ROM and send it a
                                      picture built by mkimage.py

Two hard-won details about this board's USB bridge:

  * It exposes two CDC ports. The LOWER-numbered one is FTDI channel A, the
    JTAG interface. Opening it makes macOS's serial driver claim the channel,
    after which the programmer fails with "Cable open failed" until the board
    is physically replugged. Only ever touch the higher-numbered port; that is
    what `find_port()` picks.
  * Closing and reopening the UART wedges it. Everything here runs on a single
    file descriptor, changing line settings with termios rather than reopening.

The boot banner is printed once at reset and the monitor is silent afterwards,
so `boot` holds the port open across programming to catch it. Reading after
programming shows nothing -- that is the monitor waiting for input, not a fault.
"""
import os, sys, time, glob, select, termios, subprocess

GOWIN = "/Applications/GowinIDE.app/Contents/Resources/Gowin_EDA"
PROG_DIR = f"{GOWIN}/Programmer/bin"
DEVICE = "GW2AR-18C"
BAUD = termios.B115200


def find_port():
    ports = sorted(glob.glob('/dev/cu.usbserial-*'))
    if not ports:
        sys.exit("no board found (no /dev/cu.usbserial-*)")
    return ports[-1]          # highest = channel B = the UART


def open_port(path):
    fd = os.open(path, os.O_RDWR | os.O_NONBLOCK | os.O_NOCTTY)
    a = termios.tcgetattr(fd)
    a[4] = a[5] = BAUD
    a[0] = a[1] = a[3] = 0                                   # raw
    a[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
    termios.tcsetattr(fd, termios.TCSANOW, a)
    termios.tcflush(fd, termios.TCIOFLUSH)
    return fd


def drain(fd, secs):
    got = b''
    end = time.time() + secs
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.2)
        if r:
            try:
                got += os.read(fd, 8192)
            except OSError:
                pass
    return got


def program(fs):
    r = subprocess.run([f"{PROG_DIR}/programmer_cli", "--device", DEVICE,
                        "--operation_index", "2", "--fsFile", os.path.abspath(fs)],
                       cwd=PROG_DIR, capture_output=True, text=True)
    return "Finished" in r.stdout


def wait_for(fd, token, secs):
    """Read until `token` has been seen or the time runs out."""
    got = b''
    end = time.time() + secs
    while token not in got and time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.2)
        if r:
            try:
                got += os.read(fd, 8192)
            except OSError:
                pass
    return got


def send_all(fd, data):
    """Write everything to the non-blocking port, waiting when it is full."""
    sent, last = 0, -1
    while sent < len(data):
        select.select([], [fd], [], 1.0)
        try:
            sent += os.write(fd, data[sent:sent + 1024])
        except BlockingIOError:
            continue
        pct = sent * 100 // len(data)
        if pct // 10 != last:
            last = pct // 10
            print(f"  sent {pct}%", file=sys.stderr, flush=True)
    termios.tcdrain(fd)


def load(fd, fs, image):
    data = open(image, 'rb').read()
    if not program(fs):
        sys.exit("programming failed")
    out = wait_for(fd, b'ready', 5.0)
    if b'ready' not in out:
        sys.stdout.write(out.decode('ascii', 'replace'))
        sys.exit("\nno 'ready' from the board -- is this the imgload bitstream?")
    time.sleep(0.1)
    send_all(fd, data)
    out += wait_for(fd, b'sum=', 5.0) + drain(fd, 0.5)
    want = f"sum={sum(data) & 0xFFFF:04X}"
    text = out.decode('ascii', 'replace')
    ok = want in text
    return text + (f"checksum ok ({want})\n" if ok else
                   f"*** CHECKSUM MISMATCH: expected {want}\n"), ok


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    cmd = sys.argv[1]
    fd = open_port(find_port())
    try:
        if cmd == 'boot':
            fs = sys.argv[2]
            if not program(fs):
                sys.exit("programming failed")
            # Some ROMs (memtest) run for many seconds before they finish.
            # The port cannot be reopened, so the wait has to happen here.
            out = drain(fd, float(sys.argv[3]) if len(sys.argv) > 3 else 3.0)
        elif cmd == 'send':
            time.sleep(0.2)
            for b in (sys.argv[2] + '\r').encode():
                os.write(fd, bytes([b]))
                time.sleep(0.02)          # the monitor echoes and blocks; pace it
            out = drain(fd, 2.0)
        elif cmd == 'load':
            text, ok = load(fd, sys.argv[2], sys.argv[3])
            sys.stdout.write(text)
            sys.exit(0 if ok else 1)
        elif cmd == 'read':
            out = drain(fd, float(sys.argv[2]) if len(sys.argv) > 2 else 3.0)
        else:
            sys.exit(__doc__)
    finally:
        os.close(fd)
    sys.stdout.write(out.decode('ascii', 'replace'))
    if not out:
        print("(nothing received)")


if __name__ == '__main__':
    main()
