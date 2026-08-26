# FPGA CNN Accelerator

A from-scratch CNN inference engine running entirely in Verilog on a **Tang Primer 20K**
(Gowin GW2A-18C), with no soft-core CPU and no vendor neural-net IP. A PC webcam feeds
96x96 grayscale frames over UART; the FPGA classifies the hand gesture in the frame as a
finger count from **0 to 5** and reports the result back over UART (and on the board's LEDs)
in real time.

**Real hardware accuracy: 84.3%** (253/300 held-out test images), close to the 88.1%
validation accuracy of the trained model — trained on a 3,547-image dataset collected by hand.

## Block diagram

```mermaid
flowchart TB
    subgraph PC["PC"]
        CAM["Webcam frame\n96x96 grayscale"]
    end

    subgraph IN["Frame input"]
        RX["uart_rx\n115200 baud"]
        FRAME["uart_frame.v\nwatches for 0xAA 0x55 marker,\nwrites 9216 bytes, centers -128"]
        RESIZE["resize_bsram\nGowin_SDPB, 96x96x1"]
    end

    subgraph CNN["CNN Inference"]
        direction TB
        C1["CONV1 3x3 + bias\n96x96x1 -> 48x48x8\n+ ReLU + 2x2 Pool"]
        FMA["Feature Map A\nBSRAM 48x48x8"]
        C2["CONV2 3x3 + bias\n48x48x8 -> 24x24x16\n+ ReLU + 2x2 Pool"]
        FMB["Feature Map B\nBSRAM 24x24x16"]
        C3["CONV3 3x3 + bias\n24x24x16 -> 12x12x32\n+ ReLU + 2x2 Pool"]
        FMC["Feature Map C\nBSRAM 12x12x32"]
        GAP["global_avg_pool.v\n12x12x32 -> 32 channel means"]
        FC["classifier.v\nFC layer + argmax"]

        C1 --> FMA --> C2 --> FMB --> C3 --> FMC --> GAP --> FC
    end

    subgraph WEIGHTS["Weights"]
        ROM["weight_rom.v\nint8 conv + FC weights,\nint8 per-filter biases (pROM)"]
    end

    subgraph OUT["Output"]
        UARTTX["uart_tx.v\nclass_result, 115200 baud"]
        LED["6 LEDs\none-hot finger count"]
        PC2["PC\n(class result 0-5)"]
    end

    CAM -- "0xAA 0x55 + 9216 bytes" --> RX --> FRAME --> RESIZE
    RESIZE --> C1
    ROM -.->|weights + biases| C1
    ROM -.->|weights + biases| C2
    ROM -.->|weights + biases| C3
    ROM -.->|weights| FC
    FC --> UARTTX --> PC2
    FC --> LED
```

## Module map

| Stage | File | Role |
|---|---|---|
| Frame input | `uart.v` (`uart_rx`) | UART receiver, 115200 baud, no PLL (raw 27MHz board oscillator) |
| Frame assembly | `uart_frame.v` | Watches for the `0xAA 0x55` sync marker, writes the next 9216 payload bytes into the resize BSRAM, centers each pixel (`pixel - 128`) for signed CNN math |
| Resize buffer | `Gowin_SDPB` (`gowin_sdpb/`) | 96x96x1 scratch buffer holding the incoming frame |
| Orchestration | `cnn_top.v` | Sequences conv → GAP → FC stages frame-to-frame |
| Conv/pool/bias/ReLU | `mac_array.v` | Single reusable MAC datapath, time-multiplexed across all 3 conv layers via `conv_layer_sel`; folds bias-add, ReLU, and 2x2 max-pool into its own FSM (no separate pool/relu stage) |
| Accumulator | `conv_acc.v` | 9-tap signed multiply-accumulate for one conv window |
| Feature maps | `Gowin_SDPB_A/B/C` (`gowin_sdpb/`) | On-chip BRAM scratch buffers for each conv layer's output (48x48x8, 24x24x16, 12x12x32) |
| Global pooling | `global_avg_pool.v` | Averages each of the 32 channels in feature map C down to one value each |
| Classifier | `classifier.v` | Fully-connected layer over the 32 GAP outputs, argmax → finger-count class (0-5) |
| Weights | `weight_rom.v` + `gowin_prom/` | Quantized int8 conv/FC weights and per-filter biases in on-chip pROM, generated directly from the trained model |
| Result output | `uart_tx.v` | Sends `class_result` back to the PC as a single byte once per completed classification, for automated test scripts |
| Top-level | `top.v` | Wires everything together; single clock domain, no PLL |

**Retained but unused** (`cam_line_buffer_30rows.v`, `preprocessor.v`, `pool.v`, `relu.v`): leftover from the earlier OV5640-camera design. Not instantiated anywhere in the current `top.v` hierarchy — the synthesizer doesn't compile them into the design — kept in the tree for reference rather than deleted outright.

## Hardware

- **FPGA**: Sipeed Tang Primer 20K (Gowin GW2A-18C, `GW2A-LV18PG256C8/I7`)
- **Image source**: PC webcam (OpenCV) — the OV5640 camera used in earlier revisions of this project was dropped in favor of streaming frames over UART from a PC
- **Toolchain**: Gowin EDA V1.9.11
- **PC link**: UART @ 115200 baud (both directions), USB-serial adapter

## Results

| Metric | Value |
|---|---|
| Dataset | 3,547 self-collected images, 6 classes (0-5 fingers) |
| Train/val split | 3,017 / 530 (85/15) |
| Validation accuracy (trained model) | 88.1% |
| Measured accuracy (real FPGA, 300 test images) | 84.3% |
| Logic utilization (GW2A-18C) | 1,846/20,736 LUT+ALU+ROM16 (9%) |
| Register utilization | 843/16,173 (6%) |
| Block RAM utilization | 27/46 (59%) — the binding resource, from feature-map buffering |

The ~4-point drop from validation accuracy to real hardware accuracy reflects the RTL's
int8 fixed-point implementation of the quantization-aware-trained model, not a hardware bug —
confirmed via cycle-accurate simulation against the same model run in PyTorch.

## Design notes (historical)

Working notes from the original camera-based design phase — memory addressing math, the
MAC-array FSM, and pipeline sketches. The overall CNN datapath (conv/pool FSM structure,
feature-map BRAM addressing) carried forward into the current design; the camera-specific
capture/decimation stages did not.

| | |
|---|---|
| ![Pipeline overview](docs/notes/02-pipeline-overview.jpg) | ![Feature map memory layout](docs/notes/01-feature-map-memory-layout.jpg) |
| Pipeline overview (early camera-based design) | Feature map BSRAM layout (48×48×8, 24×24×16, 12×12×32) and the conv core/accumulator split |
| ![Preprocessor scaling math](docs/notes/03-preprocessor-scaling-math.jpg) | ![ReLU, MaxPool, conv dimension flow](docs/notes/04-relu-maxpool-conv-dims.jpg) |
| `preprocessor.v` scaling math (superseded by `uart_frame.v`'s direct 96x96 write) | ReLU/MaxPool logic and the CONV1→CONV2→CONV3 channel/dimension flow (96×96×1 → 48×48×8 → 24×24×16 → 12×12×32), unchanged in the current design |
| ![BSRAM addressing](docs/notes/05-bsram-addressing.jpg) | ![FPGA block diagram and feature map questions](docs/notes/06-fpga-block-diagram-feature-maps.jpg) |
| BSRAM pixel addressing (`addr = y*96 + x`), still used | Early FPGA/RAM/MCU block sketch, plus working notes on per-feature-map addressing |
| ![mux_array.v FSM, first pass](docs/notes/07-mac-array-fsm-v1.jpg) | ![Weight ROM sizing](docs/notes/08-weight-rom-sizing.jpg) |
| `mac_array.v` FSM, first pass: `IDLE → COORD → ADDR → MAC → POOL → DONE` | Weight ROM byte counts and base addresses per conv layer (CONV1/2/3) |
| ![mux_array.v FSM, refined](docs/notes/09-mac-array-fsm-v2.jpg) | |
| `mac_array.v` FSM, refined: adds the per-channel accumulate loop and pool-index increment logic | |

## Pipeline test log (historical — OV5640 camera bring-up)

Bring-up log from when the project used a live OV5640 camera feeding the FPGA directly
over a DVP parallel interface. Superseded by the current PC-webcam-over-UART input path,
kept for reference.

| Pipeline | Expected | Actual |
|---|---|---|
| Synthetic pattern → `Gowin_SDPB` (96×96) → UART | ![](docs/tests/expected-checker8.png) | ![](docs/tests/01-actual-bsram-only.png) |
| Synthetic pattern → `preprocessor` (pre-fix) → `Gowin_SDPB` → UART | ![](docs/tests/expected-checker8.png) | ![](docs/tests/02-actual-preprocessor-buggy.png) |
| Synthetic pattern → `preprocessor` (fixed) → `Gowin_SDPB` → UART | ![](docs/tests/expected-checker4.png) | ![](docs/tests/03-actual-preprocessor-fixed.png) |
| Real camera → `dvp_capture` → `preprocessor` → `Gowin_SDPB` → UART | — | ![](docs/tests/04-actual-realcam-preprocessor-bsram.png) |
| Synthetic pattern (continuous, unfrozen) → `preprocessor` → `Gowin_SDPB` → UART | ![](docs/tests/expected-checker8.png) | ![](docs/tests/05-actual-continuous-tearing.png) |
| Real camera → `dvp_capture` → `cam_line_buffer_30rows` → UART (close / medium / far) | — | ![](docs/tests/06-actual-realcam-linebuffer-close.png) ![](docs/tests/06-actual-realcam-linebuffer-medium.png) ![](docs/tests/06-actual-realcam-linebuffer-far.png) |
| Synthetic pattern (real `cam_pclk`) → `preprocessor` → `cam_line_buffer_30rows` (96×96) → UART | ![](docs/tests/expected-checker4.png) | ![](docs/tests/07-actual-synthetic-vs-real-comparison.png) |

## Status

Complete and working end-to-end: a PC webcam feed streams over UART to the FPGA, which
classifies the hand gesture entirely on-chip (no CPU) and reports the result back over UART
and on the board's LEDs in real time, at 84.3% measured accuracy on real hardware.
