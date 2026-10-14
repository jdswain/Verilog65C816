#!/usr/bin/env python3
"""Load a program into the board with MiniMon's "ld" command and start it.

    mload.py prog.hex start [line ...]

prog.hex is Intel hex, as `as -o prog.hex` writes it; start is the
address, in hex, for the monitor's "go". The image is sent as the binary
records "ld" reads (see the monitor commands in fpga/README.md), each
acknowledged before the next. Then the terminal is passed through to the
program until control-]; with lines given, or when not at a terminal,
those are typed at the program instead and its replies printed.

The board must be at the monitor's prompt, and nothing else may have the
serial port open. It is the highest numbered /dev/cu.usbserial-* port,
as for board.py.
"""
import glob
import os
import select
import sys
import termios
import time

RECORD = 1024           # data bytes in a record


def read_hex(path):
    """-> {address: byte} of an Intel hex file."""
    mem, base = {}, 0
    for line in open(path):
        line = line.strip()
        if not line.startswith(':'):
            continue
        b = bytes.fromhex(line[1:])
        n, addr, kind, data = b[0], b[1] << 8 | b[2], b[3], b[4:4 + b[0]]
        if kind == 0:
            for i, v in enumerate(data):
                mem[base + addr + i] = v
        elif kind == 2:
            base = (data[0] << 8 | data[1]) << 4
        elif kind == 4:
            base = (data[0] << 8 | data[1]) << 16
    return mem


def record(addr, data):
    b = bytes([len(data) & 255, len(data) >> 8,
               addr & 255, (addr >> 8) & 255, addr >> 16]) + bytes(data)
    return b + bytes([sum(b) & 255])


def records(mem):
    """The image as records of consecutive bytes, and the one that ends it."""
    addrs, recs, i = sorted(mem), [], 0
    while i < len(addrs):
        a = addrs[i]
        row = [mem[a]]
        while (len(row) < RECORD and i + 1 < len(addrs)
               and addrs[i + 1] == addrs[i] + 1):
            i += 1
            row.append(mem[addrs[i]])
        i += 1
        recs.append(record(a, row))
    return recs + [record(0, b'')]


class Board:
    def __init__(self):
        ports = sorted(glob.glob('/dev/cu.usbserial-*'))
        if not ports:
            sys.exit('no board found (no /dev/cu.usbserial-*)')
        try:
            self.fd = os.open(ports[-1], os.O_RDWR | os.O_NONBLOCK | os.O_NOCTTY)
        except OSError as e:
            sys.exit('%s: %s (is a terminal program using it?)' % (ports[-1], e.strerror))
        a = termios.tcgetattr(self.fd)
        a[4] = a[5] = termios.B115200
        a[0] = a[1] = a[3] = 0
        a[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
        termios.tcsetattr(self.fd, termios.TCSANOW, a)
        termios.tcflush(self.fd, termios.TCIOFLUSH)

    def read(self, secs):
        """Whatever arrives within secs."""
        got, end = b'', time.time() + secs
        while time.time() < end:
            if select.select([self.fd], [], [], 0.02)[0]:
                try:
                    got += os.read(self.fd, 4096)
                except OSError:
                    pass
        return got

    def read_byte(self, secs):
        end = time.time() + secs
        while time.time() < end:
            if select.select([self.fd], [], [], 0.02)[0]:
                try:
                    b = os.read(self.fd, 1)
                    if b:
                        return b
                except OSError:
                    pass
        return b''

    def wait_prompt(self, secs):
        got, end = b'', time.time() + secs
        while time.time() < end:
            got += self.read_byte(0.05)
            if got.rstrip().endswith(b'>'):
                return True
        return False

    def write(self, data):
        sent = 0
        while sent < len(data):
            select.select([], [self.fd], [], 1.0)
            try:
                sent += os.write(self.fd, data[sent:sent + 256])
            except BlockingIOError:
                pass

    def type(self, line):
        """Type a line at the monitor, waiting for the echo of each
        character: it cannot take the next one before that."""
        for c in line.encode():
            self.write(bytes([c]))
            if not self.read_byte(0.5):
                sys.exit('no echo from the monitor: ' + line[:20])
        self.write(b'\r')

    def console(self, lines):
        """Type the lines given and show the replies, or be a terminal
        until control-]."""
        if lines or not sys.stdin.isatty():
            sys.stdout.write(self.read(2.0).decode('latin-1'))
            for line in lines:
                for c in (line + '\r').encode():
                    self.write(bytes([c]))
                    time.sleep(0.02)
                sys.stdout.write(self.read(2.0).decode('latin-1'))
            sys.stdout.write('\n')
            return
        tty = sys.stdin.fileno()
        saved = termios.tcgetattr(tty)
        raw = termios.tcgetattr(tty)
        raw[0] = raw[1] = raw[3] = 0
        termios.tcsetattr(tty, termios.TCSANOW, raw)
        try:
            while True:
                r = select.select([self.fd, tty], [], [])[0]
                if self.fd in r:
                    try:
                        os.write(1, os.read(self.fd, 4096))
                    except OSError:
                        pass
                if tty in r:
                    c = os.read(tty, 1)
                    if c == b'\x1d':
                        break
                    os.write(self.fd, c)
        finally:
            termios.tcsetattr(tty, termios.TCSANOW, saved)


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    mem, start, lines = read_hex(sys.argv[1]), int(sys.argv[2], 16), sys.argv[3:]
    board = Board()
    board.write(b'\r')
    if not board.wait_prompt(2.0):
        sys.exit('no prompt from the monitor')
    board.type('ld')
    board.read(0.2)                     # the new line
    began = time.time()
    for n, r in enumerate(records(mem)):
        for attempt in range(4):
            board.write(r)
            ack = board.read_byte(3.0)
            if ack == b'+':
                break
            if ack != b'-':
                sys.exit('record %d: no answer (%r); has the monitor "ld"?' % (n, ack))
        else:
            sys.exit('record %d: wrong sum four times' % n)
    sys.stderr.write('%d bytes loaded in %.1f s\n' % (len(mem), time.time() - began))
    if not board.wait_prompt(2.0):
        sys.exit('no prompt after the load')
    board.type('go %04x' % start)
    board.console(lines)


if __name__ == '__main__':
    main()
