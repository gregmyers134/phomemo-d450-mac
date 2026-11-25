# How the Phomemo D450 is driven

Everything here was observed on one printer (Phomemo D450, firmware V2.4.9), partly by
capturing what the vendor's Labelife app sends and partly by experiment. None of it comes
from vendor documentation. Where something is a reading of what was seen and not a
confirmed fact, it says so.

## The printer

- 203 dpi, 8 dots per mm. The print head is 864 dots (108 mm) wide.
- A 4x6" label is 812 x 1218 dots.
- It accepts one Bluetooth connection at a time.

## Bluetooth Low Energy

The printer advertises as `D450`. Its advertisement lists service `FEE7` only; the service
used for printing shows up after connecting.

| | UUID | Properties | Use |
|---|---|---|---|
| Service | `FF00` | | |
| Characteristic | `FF02` | write, write without response | Commands and job data |
| Characteristic | `FF01` | notify | The printer's text replies |
| Characteristic | `FF03` | notify | Flow control |

### Flow control (FF03)

Two messages were seen. Their meaning is a reading of the behaviour, confirmed by sending
a full label's data and checking the printer stayed in step:

| Bytes | Read as |
|---|---|
| `01 nn` | `nn` more packets may be sent |
| `02 lo hi` | Largest packet is `lo + 256 * hi` bytes |

On subscribing, the printer sent `01 07` and `02 F4 00`: 7 packets, 244 bytes each. It then
sent `01 01` once for each packet it had processed. A sender that counts one packet off for
each write and waits at zero ended back at exactly 7 after every exchange. A 13 kB job
goes through in about 1.2 seconds.

Writes are made without response, one packet per permission.

### Other services

The printer also lists services `FF10`, `FF80`, `18F0`, `FEE7`,
`49535343-FE7D-4AE5-8FA9-9FAFD205E455` and `E7810A71-73AE-499D-8C15-FAA9AEF0C3F2`. They were
not used or written to.

## Classic Bluetooth

The printer offers a Serial Port service (listed under the name "WeChat" on RFCOMM channel
23, with an unnamed service on channel 1), and this is what the vendor's Windows software
uses. From macOS the radio link and the service lookup worked, but opening an RFCOMM
channel failed on every channel with a general error, and the `/dev/cu.D450` serial port
macOS creates opened without the printer ever answering. Pairing was not tried.

## Commands

The printer speaks TSPL. Commands are ASCII and end in CR LF.

### Queries

Each is answered on `FF01` with one line of the form `NAME:value`.

| Command | Example reply |
|---|---|
| `SSSGETVERSION` | `SSSGETVERSION:V2.4.9` |
| `SSSGETBMAPMODE` | `SSSGETBMAPMODE:4` |

`SSSGETTYPE`, `SSSGETSN`, `SSSGETMAC` and `BTVER` are also reported to work. An unknown
command gets `Cmd error:<text>`. The first characters of a reply can go missing, so match
on the end of the name. Do not send a bare ESC status query; the firmware does not answer
and the leftover bytes corrupt the next command.

### A print job

```
SPEED 1                       sent on its own, just before the job
SIZE 108 mm,152.4 mm
REFERENCE 0,0
GAP 4.60 mm,0.00 mm
OFFSET 0 mm
DIRECTION 0,0
DENSITY 10
CLS
BITMAP 0,0,<width in bytes>,<height in dots>,4,<pieces><00 00 00 00>
PRINT 1,<copies>
```

While printing, the printer sends `SSSGETPRINTING:DOING` and then `SSSGETPRINTING:DONE`,
about 5 seconds for a 4x6" label.

### The bitmap (mode 4)

- 1 bit per dot, most significant bit first. **1 is white, 0 is black.** Rows are padded to
  whole bytes with white.
- The raster is cut into pieces of 4096 bytes; the last may be shorter.
- Each piece is compressed on its own with LZO1X and sent as a 4-byte little-endian
  compressed length followed by the compressed bytes.
- **After the last piece come four zero bytes.** Without them the printer accepts the job,
  reports no error, and prints nothing.
- Mode 3 (the whole raster compressed as one, with its length as an extra parameter) did
  not print on this printer.

The compressor here emits only literal runs and M3 matches, and always opens a stream with
at least 4 literals, which the vendor's decoder needs.

### Sending the full head width

If a job is narrower than the head (for example `SIZE 101.6 mm`), the printer centres it
and it lands about 5 mm too far right. Always send an 864-dot-wide bitmap with
`SIZE 108 mm` and place the page within it.

## Where the label sits

Measured with the calibration ruler on one printer and one roll of 4x6" labels:

- The label's left edge was about 18 dots (2.3 mm) to the left of head dot 0, so that strip
  of the label cannot be printed.
- Its right edge was at head dot 808.
- Printing starts about 10 rows (1.25 mm) above the label's top edge.

An earlier measurement from the Windows software put the right edge at head dot 813, so the
roll's sideways position varies by at least half a millimetre between loadings.
