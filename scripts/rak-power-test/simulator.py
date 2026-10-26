#!/usr/bin/env python3
"""A Modbus RTU bus for parkeze-rak-power's tests: the RAK7289CV2's power
board watchdog and battery pack as ChirpStack's RAK support talks to them.

    simulator.py <dir>

Opens two pty pairs and relays bytes between their masters, which is what
`socat pty pty` does, so the test opens one end as it would /dev/ttyUSB4 and
pymodbus serves the other. Writes the client end's path to <dir>/port once it
is serving, and appends every register write it accepts to <dir>/writes as
`slave register value` lines.

<dir>/muted, re-read on every request, lists slaves that stop answering, one
per line: a watchdog that falls silent mid-run is the case worth testing, and
a restart of the simulator would not be the same thing.

pymodbus is the independent half: libmodbus frames and checks every request on
one side and a different implementation on the other, so a register address
off by one shows up as a wrong number or an exception.
"""

import os
import select
import sys
import threading
import tty

from pymodbus.datastore import (ModbusServerContext, ModbusSlaveContext,
                                ModbusSparseDataBlock)
from pymodbus.exceptions import NoSuchSlaveException
from pymodbus.server import StartSerialServer
from pymodbus.transaction import ModbusRtuFramer

DIR = sys.argv[1]
WATCHDOG, BATTERY = 0xC8, 0x6E


class Recording(ModbusSparseDataBlock):
    def __init__(self, slave, values):
        super().__init__(values)
        self.slave = slave

    def setValues(self, address, values, *args, **kwargs):
        with open(os.path.join(DIR, 'writes'), 'a') as log:
            for i, v in enumerate(values if isinstance(values, list) else [values]):
                log.write(f'{self.slave} {address + i} {v}\n')
        super().setValues(address, values, *args, **kwargs)


def slave(holding, number):
    # zero_mode: register N on the wire is N here. The default adds one, which
    # is the off-by-one these tests exist to catch, so it must not be ours.
    empty = {0xFFFF: 0}
    return ModbusSlaveContext(
        hr=Recording(number, holding),
        ir=ModbusSparseDataBlock(empty),
        co=ModbusSparseDataBlock(empty),
        di=ModbusSparseDataBlock(empty),
        zero_mode=True,
    )


class Bus(ModbusServerContext):
    def __getitem__(self, slave_id):
        try:
            with open(os.path.join(DIR, 'muted')) as f:
                muted = {int(line) for line in f if line.strip()}
        except FileNotFoundError:
            muted = set()
        if slave_id in muted:
            raise NoSuchSlaveException(f'slave {slave_id} muted')
        return super().__getitem__(slave_id)


bus = Bus(slaves={
    WATCHDOG: slave({0x0001: 0}, WATCHDOG),
    BATTERY: slave({0x6000: 1280, 0x6003: 97, 0x6005: 2500, 0x6006: 3000}, BATTERY),
}, single=False)


def relay(a, b):
    while True:
        r, _, _ = select.select([a, b], [], [])
        for src in r:
            try:
                data = os.read(src, 1024)
            except OSError:
                return
            os.write(b if src == a else a, data)


client_master, client = os.openpty()
server_master, server = os.openpty()
for fd in (client, server):
    tty.setraw(fd)
threading.Thread(target=relay, args=(client_master, server_master), daemon=True).start()

with open(os.path.join(DIR, 'port.tmp'), 'w') as f:
    f.write(os.ttyname(client))
os.rename(os.path.join(DIR, 'port.tmp'), os.path.join(DIR, 'port'))

# ignore_missing_slaves: a slave that is not on the bus does not answer. The
# default answers for it with exception 0x0B, which no real RS485 bus does.
StartSerialServer(context=bus, framer=ModbusRtuFramer, port=os.ttyname(server),
                  baudrate=9600, bytesize=8, parity='N', stopbits=1,
                  ignore_missing_slaves=True)
