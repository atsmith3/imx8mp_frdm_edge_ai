
```text
BUG REPORT — Kinara ARA240 / i.MX8MP: Hard System Crash on v1/chat/completions Inference
Date: 2026-04-13
Reported by: Andrew

================================================================================
ENVIRONMENT
================================================================================

Board:          NXP i.MX 8MP Freedom Board (imx8mpfrdm)
BSP / OS:       NXP i.MX Release Distro 6.18 (Yocto/Wayland)
                imx-image-full
Kernel:         6.18.2-1.0.0-gf49f45233f7b (aarch64)
Root device:    /dev/mmcblk1p2 (~48 GB free)

Kinara ARA240 (PCIe M.2 x1 slot):
  PCIe address: 01:00.0
  Vendor/Device: 1e58:0002 rev 02
  Chip:         Ara2 A01
  Firmware:     v1.1.2
  Life cycle:   TESTED
  Chip part:    COMMERCIAL
  Frequencies:
    System:           1100 MHz
    Neural processor:  900 MHz
    Control processor: 1000 MHz
    DDR:              1066 MHz

Installed Kinara packages:
  rt-sdk-ara2          2.0.4
  eiq-aaf-connector    2.0.0
  llm-edge-studio      2.0.0

Model under test: Qwen2.5-Coder-1.5B
Model path:       /usr/share/llm/Qwen2.5-Coder-1.5B/

================================================================================
SYMPTOM
================================================================================

The system hard-crashes (complete, unrecoverable hang) when an inference request is
sent to the OpenAI-compatible REST API endpoint POST /v1/chat/completions.

Observed behavior:
  - No output to serial console at any point during or after the crash.
  - System becomes completely unresponsive.
  - Recovery requires a physical power cycle — soft reset does not work.
  - Reproducible on every attempt.
  - Occasionally, one successful completion response is returned before the
    second request triggers the crash with identical symptoms.

================================================================================
WHAT IS WORKING (PRE-CRASH STATE CONFIRMED HEALTHY)
================================================================================

All of the following checks pass immediately before triggering the crash:

  1. Kinara proxy daemon:
       $ systemctl status rt-sdk-ara2
       -> Active: active (running)

  2. API connector:
       $ systemctl status eiq-aaf-connector
       -> Active: active (running)

  3. Hardware diagnostics:
       $ chip_info.sh
       -> Returns all chip stats successfully (see Environment section above)

  4. PCIe driver and link:
       $ lspci -vv -s 01:00.0 | grep -E "driver|LnkSta"
       -> Kernel driver in use: uiodma
       -> LnkSta: Speed 2.5GT/s (downgraded), Width x1 (downgraded)

  5. Model loaded and ready:
       $ curl http://localhost:8000/v1/models
       -> Returns Qwen2.5-Coder-1.5B with status ready

================================================================================
KEY OBSERVATION — PCIe LINK DOWNGRADE
================================================================================

The lspci output consistently shows:

  LnkSta: Speed 2.5GT/s (downgraded), Width x1 (downgraded)

Both link speed and width are reported as downgraded from their negotiated/expected
values. This downgrade is present even when the system is otherwise healthy.
The hypothesis is that the PCIe link is marginal and fails under the DMA load
generated during neural inference, causing a kernel panic or machine check error
that produces no console output before the CPU/bus halts.

================================================================================
REPRODUCTION STEPS
================================================================================

Step 1 — Confirm system is healthy:
  $ systemctl status rt-sdk-ara2
  $ systemctl status eiq-aaf-connector
  $ curl http://localhost:8000/v1/models

Step 2 — Send an inference request (triggers crash):
  $ curl -X POST http://localhost:8000/v1/chat/completions \
      -H "Content-Type: application/json" \
      -d '{
        "model": "Qwen2.5-Coder-1.5B",
        "messages": [{"role": "user", "content": "Hello"}]
      }'

Expected: JSON completion response.
Actual:   System hangs. No response. No serial output. Power cycle required.

Note: On rare occasions one response returns successfully; the crash occurs
on the immediately following request.

================================================================================
ATTEMPTED DEBUGGING
================================================================================

In an attempt to capture kernel output at the moment of crash, the following
kernel parameters were set in the test script before issuing the curl request:

  echo 8 > /proc/sys/kernel/printk          (maximum verbosity)
  echo 1 > /proc/sys/kernel/printk_delay    (enable printk delay)
  echo Y > /sys/module/printk/parameters/console_suspend

Despite these settings, no kernel output appears on the serial console either
during the inference call or at the moment of crash. This suggests the system
halts at a level that prevents the UART from flushing (e.g., early machine
check, PCIe fatal error, or ARM SError interrupt).
```


### Resolution

```
Update Firmware from 1.1.1 to 2.0.0

# In U Boot Args:
u-boot> 
```