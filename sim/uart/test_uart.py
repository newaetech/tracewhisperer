import cocotb
from cocotbext_uart import UARTParity
from cocotbext_uart import UARTConfig
from cocotbext_uart import UARTModule
from cocotbext_uart import UARTSignals
from cocotb.triggers import RisingEdge, ClockCycles, Join, Lock, Event
from cocotb.clock import Clock
from cocotb.queue import Queue
from cocotb.handle import Force, Release
from cocotb.log import SimLogFormatter
#from cocotb.regression import TestFactory
import random
import math
import logging
import os

# Note: this could also be place in individual test functions by replacing root_logger by dut._log.
root_logger = logging.getLogger()
logfile = os.getenv('LOGFILE', 'make.log')
print('Logfile = %s' % logfile)
fh = logging.FileHandler(logfile, 'w')
fh.setFormatter(SimLogFormatter())
root_logger.addHandler(fh)

class Harness(object):
    def __init__(self, dut, reps, baud, period, data_bits, stop_bits, parity_bit, parity_enabled, parity_ignored, parity_accept_errors):
        self.dut = dut
        self.reps = reps
        self.baud = baud
        self.tests = []
        self.errors = 0
        self.period = period
        # Actual seed is obtained only if RANDOM_SEED is defined on vvp command line (otherwise you get 0)
        # regress.py always specifies the seed so this is fine.
        self.dut._log.info("seed: %d" % int(os.getenv('RANDOM_SEED', '0')))
        self.clock = Clock(dut.clk, self.period, units="ns")
        clk_thread = cocotb.start_soon(self.clock.start())
        self.bit_clocks = int( 1/(self.baud) / (self.period * 1e-9) )
        #  initialize all DUT input values:
        self.dut.bit_rate.value = self.bit_clocks
        self.dut.data_bits.value = data_bits
        self.dut.stop_bits.value = stop_bits
        self.dut.parity_bit.value = parity_bit
        if parity_ignored:
            self.dut.parity_enabled.value = 0
        else:
            self.dut.parity_enabled.value = parity_enabled
        self.dut.parity_accept_errors.value = parity_accept_errors
        #self.dut.rxd_ack.value = 0 // driven by uart_cocowrapper.v
        self.dut.reset_n.value = 1


    async def reset(self):
        await ClockCycles(self.dut.clk, 10)
        self.dut.reset_n.value = 0
        await ClockCycles(self.dut.clk, 4)
        self.dut.reset_n.value = 1

    def register_test(self, test):
        """ Add to list of running tests, so that we can later wait for all of
        them to complete via all_tests_done().
        """
        self.tests.append(test)

    async def all_tests_done(self):
        """ Wait for all tests which were registered via register_test() to finish.
        """
        for test in self.tests:
            await test.done()
        await ClockCycles(self.dut.clk, 10) # to give time for fifo_watch errors to be seen

    def start_tests(self):
        """ Wait for all tests which were registered via register_test() to finish.
        """
        for test in self.tests:
            test.start()

    def inc_error(self):
        self.errors += 1
        self.dut.errors.value = self.errors

    @staticmethod
    def hexstring(string, max_chars=24):
        """ Convenience function to put a string onto the simulation waveform."""
        data = 0
        for i,j in enumerate(string[:max_chars]):
            data += (ord(j) << ((max_chars-1-i)*8))
        return data


class UartTest(object):
    def __init__(self, dut, harness, reps, baud, data_bits, stop_bits, parity_bit, parity_enabled, parity_errors, parity_accept_errors):
        self.dut = dut
        self.harness = harness
        self.name = 'UART test'
        self.baud = baud
        self.reps = reps
        self.data_bits = data_bits
        self.parity_errors = parity_errors
        self.parity_accept_errors = parity_accept_errors
        self.write_queue = Queue()
        if parity_enabled:
            if parity_bit:
                parity = UARTParity.ODD
            else:
                parity = UARTParity.EVEN
        else:
            parity = UARTParity.NONE
        self._uart_config = UARTConfig(baud=baud, 
                                       parity=parity,
                                       bits=data_bits,
                                       stopbits=stop_bits)
        self._uartsig = UARTSignals(tx = dut.rxd,
                                    rx = dut.txd,
                                    ctsn = None,
                                    rtsn = None)
        self._uart_drv = UARTModule(config=self._uart_config,
                        signals=self._uartsig,
                        clk=self.harness.clock)
        self._coro = None
        self.errors = 0

    def start(self) -> None:
        """Start test thread"""
        if self._coro is not None:
            raise RuntimeError("Capture already started")
        self._coro = cocotb.start_soon(self._run())
        self._ccoro = cocotb.start_soon(self._check_thread())

    def stop(self) -> None:
        """Stop test thread"""
        if self._coro is None:
            raise RuntimeError("Capture never started")
        self._coro.kill()
        self._coro = None

    def running(self) -> bool:
        if self._coro is None or self._coro.done():
            return False
        else:
            return True

    async def done(self) -> None:
        """ wait for _run() to complete """
        await Join(self._coro)
        # ensure last word is received:
        await ClockCycles(self.dut.clk, self.harness.bit_clocks*5)
        if not self.write_queue.empty():
            self.harness.inc_error()
            self.dut._log.error("Write queue still contains %d words!" % self.write_queue.qsize())
        if self.errors:
            self.dut._log.error("%6s test done, failed with %d errors" % (self.name, self.errors))
        else:
            self.dut._log.info("%6s test done: passed!" % self.name)

    async def _run(self) -> None:
        self.dut._log.debug('_run starting')
        await ClockCycles(self.dut.clk, 30)
        for i in range(self.reps):
            word = random.randint(0,(2**self.data_bits)-1)
            if self.parity_errors and random.randint(0,1):
                parity_error = 1
            else:
                parity_error = 0
            self.dut._log.debug("rep %d: sending %4x (parity_error:%d)" % (i, word, parity_error))
            if not (parity_error and not self.parity_accept_errors):
                self.write_queue.put_nowait(word)
            await self._uart_drv.send(word, parity_error=parity_error)
            #await ClockCycles(self.dut.clk, random.randint(0, self.harness.bit_clocks*30)) TODO: temporary!

    async def _check_thread(self) -> None:
        self.dut._log.debug('%6s _check_thread starting' % self.name)
        #await ClockCycles(self.dut.clk, 100)
        i = 0
        while True:
            await self.wait_signal(self.dut.rxd_syn, 1, self.dut.clk)
            rdata = self.dut.rxd_data.value >> (9 - self.data_bits)
            self.dut._log.debug("%6s rep %d:  got raw %x" % (self.name, i, self.dut.rxd_data.value))
            edata = self.write_queue.get_nowait()
            if rdata != edata:
                self.harness.inc_error()
                self.dut._log.error("%6s rep %d: Expected %4x, got %4x" % (self.name, i, edata, rdata))
            else:
                self.dut._log.debug("%6s rep %d: Expected %4x, got %4x" % (self.name, i, edata, rdata))
            await self.wait_signal(self.dut.rxd_syn, 0, self.dut.clk)
            i += 1

    #@staticmethod - hmm, looks like staticmethod + async don't play well together?
    async def wait_signal(self, signal, value, clock):
        while signal != value:
            await ClockCycles(clock, 1)


@cocotb.test(timeout_time=100000, timeout_unit="us")
#@cocotb.test(skip=True)
async def uart_test(dut):
    reps  = int(os.getenv('REPS', '2'))
    baud  = int(os.getenv('BAUD', '115200'))
    period = int(os.getenv('PERIOD', '100'))

    data_bits = int(os.getenv('DATA_BITS', '8'))
    stop_bits = int(os.getenv('STOP_BITS', '1'))
    parity_bit = int(os.getenv('PARITY_BIT', '0'))
    parity_enabled = int(os.getenv('PARITY_ENABLED', '0'))
    parity_ignored = int(os.getenv('PARITY_IGNORED', '0'))
    parity_errors = int(os.getenv('PARITY_ERRORS', '0'))
    parity_accept_errors = int(os.getenv('PARITY_ACCEPT_ERRORS', '0'))

    dut._log.info("DATA_BITS: %d" % data_bits)
    dut._log.info("STOP_BITS: %d" % stop_bits)
    dut._log.info("PARITY_BIT: %d" % parity_bit)
    dut._log.info("PARITY_ENABLED: %d" % parity_enabled)

    harness = Harness(dut, reps, baud, period, data_bits, stop_bits, parity_bit, parity_enabled, parity_ignored, parity_accept_errors)
    await harness.reset()

    uarttest = UartTest(dut, harness, reps, baud, data_bits, stop_bits, parity_bit, parity_enabled, parity_errors, parity_accept_errors)

    harness.register_test(uarttest)
    harness.start_tests()
    await harness.all_tests_done()
    assert harness.errors == 0

