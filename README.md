# Phomemo D450 for Mac

Print to a Phomemo D450 label printer from the normal Print dialog of any Mac app.

The D450 has no macOS driver; the vendor's Labelife app is the only way to print to it. This
project is a small background service that makes the printer show up as an ordinary printer.
macOS sends it a page, it finds the label on the page, and it sends the label to the printer
over Bluetooth Low Energy.

It is written in Swift using Apple's frameworks only. There is no third-party code and
nothing is downloaded: you build it from the source in this repository.

Not affiliated with Phomemo or Zhuhai Quin Technology.

## What it handles

- A 4x6" PDF prints as it is.
- A shipping label on a US Letter or A4 page is found, cut out and printed at its exact
  size, so barcodes stay sharp. Dashed "cut here" lines are left out.
- A label drawn larger than 4x6" is shrunk to fit.
- Packing slips, return records and instruction pages are shrunk onto a label of their
  own, so a label printer can be your only printer.

## Requirements

- A Mac with Bluetooth, macOS 12 or later.
- The Xcode Command Line Tools (`xcode-select --install`).
- A Phomemo D450 with 4x6" labels.

## Install

```bash
git clone https://github.com/gregmyers134/phomemo-d450-mac.git
```

```bash
cd phomemo-d450-mac
```

```bash
scripts/install.sh
```

This builds the service, installs it as "D450 Print Service" in `~/Applications`, sets it to
start at login, and adds two printers. To install for every user of the Mac instead (asks
for an administrator password):

```bash
scripts/install.sh --all-users
```

The first time you print, macOS asks whether "D450 Print Service" may use Bluetooth. Click
Allow. Each user of the Mac is asked once.

To remove it, run `scripts/uninstall.sh` (with `--all-users` if you installed that way).

The printer accepts one Bluetooth connection at a time. Close Labelife on any phone or PC
that is connected to it. The service connects only while a job is printing.

## Printing

Print from any app. Leave the paper size as the document's own (US Letter for most return
labels) and the scale at 100% / Actual size. Do not use "Scale to fit".

Two printers are added. They differ only for a page that holds a label and other things:

| Printer | Prints |
|---|---|
| Phomemo D450 label printer | The label. The rest of that page is left out. |
| Phomemo D450 label + rest of page | The label, then the rest of that page (instructions, receipt, packing slip) shrunk onto a second label. |

Every page that has ink prints. A page of instructions or a packing slip is shrunk onto one
label, turned sideways if that prints larger. For a PDF with pages you do not need, choose
the pages in the Print dialog.

## What happens to a page

- A 4x6" page prints as it is.
- A 6x4" landscape page is turned 90 degrees.
- Any other page (Letter, A4) is searched for its label. Dashed "cut here" lines, and a
  scissors mark on them, are taken out first so that one close to a label is not read as
  part of it. Then:
  1. If everything on the page fits on the label, the blank space round it is dropped and
     it is centred at its exact size (no resampling, so barcodes stay sharp).
  2. If everything on the page has the shape of a label but is bigger, it is one enlarged
     label and is shrunk to fit. Anything shrunk keeps a 1.5 mm margin, so none of it falls
     in the strips at the label's edges that the printer cannot reach.
  3. Otherwise the page is split into blocks at its blank bands (4 mm or wider). A block
     that fits the label at exact size, upright or sideways, and fills at least half of it
     is taken as the label. Cut lines, instructions and receipts on the same page are left
     out. Two such blocks give two labels.
  4. Failing that, the largest label-shaped block is shrunk to fit; failing that, the whole
     page is.
- A page with no ink is skipped instead of feeding a blank label.

## Settings

Optional. Put a JSON file at `~/Library/Application Support/D450Mac/config.json` and restart
the service (log out and in, or run `scripts/install.sh` again). Print the defaults with:

```bash
swift run -c release d450d --print-config
```

Any key may be left out. A misspelt key or an out-of-range value stops the service at start.

| Key | Default | Meaning |
|---|---|---|
| `port` | 8631 | Loopback port |
| `printerName` | "D450" | Name the service reports |
| `bluetoothName` | "D450" | Bluetooth name the printer is found by |
| `density` | 10 | Print darkness, 0 to 15 |
| `speed` | 1 | 1 to 8 |
| `gapMm` | 4.6 | Gap between labels |
| `leftDot` | 0 | Head column (0-based) where the label's left column goes, 0 to 52 |
| `topDot` | 10 | Row of the print (0-based) where the label's top row goes, 0 to 80 |
| `threshold` | 128 | Grey values below this print black |
| `dither` | false | Floyd-Steinberg dithering instead of the threshold |
| `rotateClockwise` | true | Direction a landscape page is turned |
| `skipBlankPages` | true | Drop pages with no ink |
| `advertiseURF` | false | Also offer Apple Raster to the print system |
| `doneTimeoutSeconds` | 45 | How long to wait for the printer to report a label as printed |

## Calibration ruler

If a print sits off-centre, print the ruler (one label):

```bash
swift run -c release d450-ruler
```

Each bar is numbered with the head dot or row where it starts or ends, in steps of 4 dots
(0.5 mm). At each edge of the label, find where the bars stop reaching the edge: that
number is the head dot or row at that edge. `leftDot` should be the head dot at the label's
left edge, or 0 if the edge is beyond the first dot. `topDot` should be the row at the
label's top edge.

Measured on 2026-11-22 with 4x6" labels: the left edge was about 18 dots (2.3 mm) to the
left of head dot 0, where the head cannot print; the right edge was at head dot 808; the top
edge was at row 10. So the defaults are `leftDot` 0 and `topDot` 10. With them the page is
level with the top of the label, the last 10 rows (1.25 mm) of a full-height page are not
printed, and a full-width page loses its last 4 dots (0.5 mm) off the right edge.

The ruler needs the Bluetooth link to itself, so stop the installed service first
(`scripts/uninstall.sh`, then `scripts/install.sh` afterwards) or it may find the printer
busy. To see the ruler page without printing it:

```bash
swift run -c release d450-ruler --png ruler.png
```

## Troubleshooting

- **Log:** `~/Library/Logs/D450Mac/d450d.log` says what was received and what was done with
  each page.
- **Nothing prints, log says the printer was not found:** the printer is off, out of range,
  or connected to another device. Close Labelife on the phone or PC.
- **Log says Bluetooth is not allowed:** allow "D450 Print Service" in System Settings >
  Privacy & Security > Bluetooth.
- **Weak signal warning in the log:** move the printer closer to the Mac.
- **Print is off-centre:** see Calibration ruler above.
- **Two users logged in at once:** only one copy of the service can listen. The second
  waits; print jobs from both users go through the first.

## Running it by hand

Useful for trying it out or working on the code. Run these from the repository folder.

```bash
swift run -c release d450-selftest
```

runs the checks; it prints `N checks, 0 failed`. It opens a loopback port for a few seconds
and does not need a printer.

```bash
swift run -c release d450d --dry-run out
```

runs the service without a printer: each label is written to `out` as a PNG, next to the
exact bytes that would have been sent and the document as macOS sent it.

```bash
swift run -c release d450d
```

runs the service in the foreground, printing for real. Stop an installed copy first; only
one can use port 8631. The print queues are added with:

```bash
lpadmin -p D450 -E -v ipp://localhost:8631/ipp/print -m everywhere
```

```bash
lpadmin -p D450_all -E -v ipp://localhost:8631/ipp/all -m everywhere
```

Test tools, none of which uses paper:

| Command | What it does |
|---|---|
| `swift run -c release d450-bletest` | Sends a whole label's data with the PRINT command left off and checks the printer stays in step |
| `swift run d450-bleprobe` | Connects over Low Energy, lists services, sends one version query |
| `swift run d450-blescan` | Listens for the printer's Low Energy advertisement; connects to nothing |
| `swift run d450-probe <address>` | Tries Classic Bluetooth and reports each stage |
| `swift run d450-serial` | Tries the `/dev/cu.D450` serial port macOS creates |

## How it works

macOS prints to `ipp://localhost:8631`. The service answers as a driverless ("IPP
Everywhere") printer, so macOS renders each page itself and sends it as a PWG Raster image
at the printer's 203 dpi. The service finds the label, turns it into a 1-bit bitmap, wraps
it in the printer's TSPL commands with LZO compression, and sends it over Bluetooth Low
Energy using the printer's own flow control. [docs/PROTOCOL.md](docs/PROTOCOL.md) has the
details of the printer's protocol as observed.

The service listens on the loopback address only. It refuses requests whose Host header is
not localhost and POSTs that are not `application/ipp`, so a web page in a browser cannot
send it print jobs. Any user of the same Mac can print through it.

## Source layout

| File | Contents |
|---|---|
| `Sources/D450Core/Lzo.swift` | LZO1X compressor (port of the C# one) and a full LZO1X decompressor |
| `Sources/D450Core/MonoBitmap.swift` | 1-bit raster in printer layout (MSB first, 1 = white) |
| `Sources/D450Core/Tspl.swift` | TSPL job builder (BITMAP mode 4) and a job parser |
| `Sources/D450Core/Raster.swift` | PWG Raster and Apple Raster (URF) decoders |
| `Sources/D450Core/GrayImage.swift` | 8-bit image: crop, turn, place, area-average resize |
| `Sources/D450Core/Layout.swift` | Page to label: as-is, turn, auto-crop, threshold or dither |
| `Sources/D450Core/Ipp.swift` | IPP message encoding and decoding |
| `Sources/D450Core/IppPrinter.swift` | IPP operations, job states, printer attributes |
| `Sources/D450Core/HttpServer.swift` | Loopback HTTP/1.1 listener on BSD sockets |
| `Sources/D450Core/Service.swift` | Connects the listener to the IPP printer; request checks |
| `Sources/D450Core/Sink.swift` | Where labels go; the dry-run file writer |
| `Sources/D450Core/BlePrinter.swift` | Bluetooth Low Energy link to the printer and its flow control (macOS only) |
| `Sources/D450Core/Png.swift` | PNG writer for dry-run images |
| `Sources/D450Core/Config.swift` | Config file |
| `Sources/d450d/` | The service program |
| `scripts/`, `packaging/` | Installer, uninstaller, and the app and launch-agent templates |
| `Sources/D450Core/Ruler.swift`, `Sources/d450-ruler/` | Calibration ruler page and the tool that prints it |
| `Sources/d450-bletest/` | No-paper test of the Bluetooth link |
| `Sources/d450-probe/`, `d450-serial/`, `d450-bleprobe/`, `d450-blescan/` | Connection test tools |
| `Sources/d450-selftest/` | Self-test, sample writer, and `lzo-c` / `lzo-d` file tools |

## Status and limits

- `scripts/install.sh` and the start-at-login setup are new and have not yet been run on a
  Mac. Everything under "Running it by hand" has been.
- Developed and tested with one D450 (firmware V2.4.9) and one Mac. Other firmware
  versions may behave differently.
- Bluetooth Low Energy only. Classic Bluetooth did not work from macOS in testing: the
  printer's serial service is listed, but no channel to it would open.
- 4x6" labels only.
- The print position defaults were measured on one printer. If yours prints off-centre,
  print the calibration ruler and set `leftDot` and `topDot`.
- The app is signed locally when you install it. After rebuilding, macOS may ask about
  Bluetooth again.
- The "rest of page" goes onto one label. A full page of dense text comes out small.
- Two labels side by side on one sheet are printed as two labels only if the pair is not
  itself label-shaped; otherwise they are taken for one enlarged label.

## License

MIT. See [LICENSE](LICENSE).
