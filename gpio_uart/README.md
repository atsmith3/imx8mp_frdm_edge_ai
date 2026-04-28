# UART3 Loopback Test — NXP FRDM-IMX8MP

Hardware loopback test for UART3 (`/dev/ttymxc2`) on the NXP FRDM-IMX8MP
board. Transmits a fixed test string and verifies the received data matches.
An interactive terminal program is also provided.

---

## Hardware

### UART device

| Device        | Peripheral | Baud   | Format |
|---------------|------------|--------|--------|
| `/dev/ttymxc2` | UART3     | 115200 | 8N1    |

`/dev/ttymxc0` (UART1) is reserved by the Bluetooth HCI subsystem.
`/dev/ttymxc1` (UART2) is the system console. Neither may be used.

### J18 header pin mapping

| J18 Pin | Net Name  | ECSPI1 Pad  | GPIO      | Ball |
|---------|-----------|-------------|-----------|------|
| 7       | UART3_CTS | ECSPI1_SCLK | GPIO5_IO6 | AD20 |
| 8       | UART3_TXD | ECSPI1_MISO | GPIO5_IO8 | AC20 |
| 10      | UART3_RXD | ECSPI1_MOSI | GPIO5_IO7 | AF20 |
| 11      | UART3_RTS | ECSPI1_SS0  | GPIO5_IO9 | AE20 |

### Loopback wiring

Connect **J18 Pin 8 (TX)** to **J18 Pin 10 (RX)** with a jumper wire.

For flow-control loopback (optional — test programs use `CLOCAL` and do not
require it): connect **J18 Pin 11 (RTS)** to **J18 Pin 7 (CTS)**.

---

## Build

```sh
make CC=gcc
```

Produces the `uart_loopback_test` binary.

---

## Program

### uart_loopback_test

Automated loopback test. Writes a fixed 16-byte string to the UART and reads
it back. Reports PASS or FAIL.

```sh
./uart_loopback_test [device]
```

Default device is `/dev/ttymxc2`. The jumper between J18 Pin 8 and Pin 10
must be installed before running.

Example output — pass:

```
Device : /dev/ttymxc2
TX     : "LOOPBACK_TEST_OK" (16 bytes)
RX     : "LOOPBACK_TEST_OK" (16 bytes)
RESULT : PASS
```

Example output — fail (no jumper or wrong pins):

```
Device : /dev/ttymxc2
TX     : "LOOPBACK_TEST_OK" (16 bytes)
RX     : timeout after 2 s — received 0/16 bytes
RESULT : FAIL (check jumper between J18 Pin 8 (TX) and Pin 10 (RX))
```

Exit code is 0 on PASS, 1 on FAIL.

---

## Notes

- `CLOCAL` is set on the UART. This is required on i.MX8 — without it,
  floating CTS/DCD lines stall `open()` and `read()`.
- The UART3 pads are muxed from the ECSPI1 pad group. The ECSPI1 peripheral
  is not active; UART3 owns these pads exclusively.
- Pin assignments are documented in `gpio_header.csv` (schematic net names)
  and `UART_HW.md` (kernel pinctrl analysis and investigation log).
- Source: `uart_loopback_test.c`.
