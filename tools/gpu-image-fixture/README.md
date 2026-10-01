# gpu-image-fixture

A fixed **16-image / 16 MiB** resize workload. It preserves the original
upstream registry-ceiling benchmark so timings remain comparable after the
fork raises its registry to 129 images. It does not saturate the fork's new
registry capacity.

The original Direct2D renderer discarded textures on resize. The fork's
D3D11 flip-model renderer keeps them across resize; this workload measures the
same visible images on either implementation. Four columns of fixed-size
cells keep all sixteen textures visible in the harness's smallest window.
The tests verify that this workload fits the registry and each texture fits
the per-image pixel budget.

## Running it

```bash
SCRIPTC_CC=zigcc ./zig-out/bin/native.exe build tools/gpu-image-fixture --yes
tools/gpu-image-fixture/zig-out/bin/gpu-image-fixture.exe
```

The status line reports what actually registered (`16/16 textures · 512x512
RGBA8 · 16384 KiB resident`), so a partial run is visible rather than silent.

### Knobs

Both clamp rather than fail, and both are read once at startup:

| variable | range | default |
|---|---|---|
| `NATIVE_SDK_FIXTURE_IMAGES` | 1–16 | 16 |
| `NATIVE_SDK_FIXTURE_EXTENT` | 8–512 | 512 |

Walking those two axes is how the cost model below was fitted without a
rebuild per data point.

## Measuring with it

`NATIVE_SDK_GPU_PROFILE=<path>` makes the Direct2D renderer log one
`present` line and one `paint` line per event (see the `GpuProfileLog`
comment in `gpu_surface_renderer.cpp` for the field list). Unset — every
shipped run — each probe is one predicted branch and nothing is written.

`tools/windows-truth/gpu-resize-profile.ps1` drives the whole loop: launch
under the profiler, run a synthetic `SetWindowPos` resize sweep, optionally
repeat it as a real `WM_ENTERSIZEMOVE` border drag, close cleanly so the log
flushes, and reduce the result.

```powershell
powershell -NoProfile -File tools\windows-truth\gpu-resize-profile.ps1 -Label tex16x512
powershell -NoProfile -File tools\windows-truth\gpu-resize-profile.ps1 -Label tex16x128 -Images 16 -Extent 128
powershell -NoProfile -File tools\windows-truth\gpu-resize-profile.ps1 -AppDir examples/gpu-dashboard -ProcessName gpu-dashboard -Label dashboard
```

Unlike `perf-input.ps1`, the sweep needs no interactive scheduled-task hop —
`SetWindowPos` is not desktop input. `-Drag` does need the console desktop.

## What it measured (2026-08-11, 240 Hz desktop, `main` @ 833e79e4)

Per resize step, p50 milliseconds, 128–160 steps per configuration:

| textures | edge | resident | target setup | image upload | render¹ | blit |
|---|---|---|---|---|---|---|
| 1 | 8 | ~0 | 0.149 | 0.019 | 0.398 | 0.591 |
| 16 | 128 | 1 MiB | 0.156 | 0.303 | 0.745 | 0.589 |
| 16 | 256 | 4 MiB | 0.223 | 0.642 | 1.151 | 1.060 |
| 8 | 512 | 8 MiB | 0.202 | 0.803 | 1.318 | 0.687 |
| 16 | 512 | 16 MiB | 0.149 | **1.441** | 1.806 | 0.549 |

¹ `render` contains `image upload`: the uploads happen inside the display-list
walk, so exclusive draw cost is the difference.

Fitting the two axes gives roughly **15 µs per texture + 0.07 ms per MiB**.
The upload cost is flat across surface size (1.49–1.53 ms from 0.9 to 3.1
megapixels) because it depends on texture bytes, not window area.

## Note on media surfaces

Media-surface textures (`canvas.media_surface_image_id_bit`, 4 channels ×
8 MiB) reach the host through the same `uploadGpuSurfaceImage` seam and land
in the same per-surface `image_bitmaps_` map, so `releaseImageBitmaps()`
flushes them too. Their *marginal* cost from the flush is near zero while a
producer is pushing, because a new frame bumps the resource serial and
`ensureImageBitmap` re-uploads every frame regardless. A **paused** producer
is the exception: its texture is stable, so the flush alone forces the
re-upload, and 32 MiB of paused video extrapolates to roughly 2.3 ms per
resize step on top of the registered-image cost. This fixture does not
measure that case.
