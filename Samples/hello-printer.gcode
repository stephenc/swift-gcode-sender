; Small three-layer dry-run path for 3D printer preview and motion testing
; No extrusion or heating commands are included.
G21
G90
G28
G0 X10 Y10 Z0.2
G1 X40 Y10 F1200
G1 X40 Y30
G1 X10 Y30
G1 X10 Y10
G0 Z0.4
G1 X12 Y12
G1 X38 Y12
G1 X38 Y28
G1 X12 Y28
G1 X12 Y12
G0 Z0.6
G1 X14 Y14
G1 X36 Y14
G1 X36 Y26
G1 X14 Y26
G1 X14 Y14
