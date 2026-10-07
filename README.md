# G-code Sender

A native macOS SwiftUI sender for serial GRBL-compatible controllers and FluidNC over WebSocket. It previews and validates toolpaths against saved machine profiles before streaming them one acknowledged line at a time.

## Run

Requires macOS 14 or newer and Swift 6. Open `Package.swift` in Xcode and run the **GCodeSender** scheme, or use:

```sh
scripts/run.sh
```

To produce a signed application bundle and distributable ZIP:

```sh
scripts/build-app.sh
```

Without an installed Apple certificate this creates an ad-hoc signed app. For Developer ID signing, install the certificate and run `SIGNING_IDENTITY="Developer ID Application: …" scripts/build-app.sh`; notarization requires the corresponding Apple developer credentials.

The app starts with example 2D Plotter and 3D Printer profiles. Configure the serial port or FluidNC WebSocket URL in **Settings**, then open one of the files under `Samples/`.

## Included test files

- `Samples/hello-world.svg` exercises SVG conversion and the 2D preview.
- `Samples/hello-plotter.gcode` exercises two-height pen-up/pen-down handling.
- `Samples/hello-printer.gcode` exercises the rotatable multi-layer 3D preview and is a no-extrusion dry run (it homes first).

Run the core parser/converter tests with `scripts/test.sh`.

## Current SVG support

Line, rectangle, polyline, polygon, circle, ellipse, and path commands `M`, `L`, `H`, `V`, and `Z` are supported. SVG coordinates are interpreted as millimetres. Curves, transforms, text, and fill-to-hatch conversion are not yet expanded; convert those to paths/line segments in the drawing application first.

FluidNC 4 advertises its synchronous WebSocket on the HTTP server port, normally `ws://<host>/` on port 80. Older port-81 profiles automatically fall back to port 80; the URL remains editable per profile.

## License

Licensed under the [Apache License 2.0](LICENSE).
