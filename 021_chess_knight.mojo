"""
An animated fullscreen fragment-shader example.

The lowest-friction way to play with GPU fragment shaders in wgpu-mojo: the Mojo
side just opens a window, owns a tiny uniform buffer, and draws one fullscreen
triangle pair every frame. ALL the visuals live in the WGSL string below — to
make your own effect you only edit the `shade` function.

Uniforms handed to the shader (see the `Uniforms` struct in WGSL):
    resolution : vec3<f32>   viewport size in pixels (z = 1.0)
    time       : f32         seconds since start
    mouse      : vec4<f32>   mouse (xy = current, zw = click) — 0 here (no input wired)
    frame      : f32         frame counter

This file is the simplest of the fragment-shader examples (a classic plasma);
see examples/metaballs.mojo for a 2D signed-distance-field scene.

Run:
    pixi run example-plasma
"""

from wgpu import (
    Instance,
    WGPUBufferUsage, WGPUShaderStage, WGPU_WHOLE_SIZE,
    WGPUBindGroupLayoutEntry, WGPUBindGroupEntry,
    WGPUColor, BGL,
)
from wgpu.rendercanvas import RenderCanvas
from wgpu._ffi.nulls import null_opaque
from std import io

from std.time import perf_counter_ns
from std.memory import UnsafePointer

comptime WIN_W = 960
comptime WIN_H = 540

# ---------------------------------------------------------------------------
# WGSL — the only part you edit to make a new effect.
#
# `shade` returns the colour for one pixel. `frag_coord` is in pixels with the
# origin at the bottom-left; the host fragment entry flips Y and calls it once
# per pixel.
# ---------------------------------------------------------------------------
comptime PLASMA_WGSL = """
struct Uniforms {
    resolution: vec3<f32>,
    time: f32,
    mouse: vec4<f32>,
    frame: f32,
    _pad0: f32,
    _pad1: f32,
    _pad2: f32,
}
@group(0) @binding(0) var<uniform> U: Uniforms;

// ---- fullscreen triangle pair (no vertex buffer needed) -------------------
@vertex
fn vs_main(@builtin(vertex_index) idx: u32) -> @builtin(position) vec4<f32> {
    var p = array<vec2<f32>, 6>(
        vec2<f32>(-1.0, -1.0), vec2<f32>(1.0, -1.0), vec2<f32>(-1.0, 1.0),
        vec2<f32>(-1.0, 1.0), vec2<f32>(1.0, -1.0), vec2<f32>(1.0, 1.0),
    );
    return vec4<f32>(p[idx], 0.0, 1.0);
}

// ===========================================================================
// EDIT BELOW — return the colour for one pixel.
// ===========================================================================
fn shade(frag_coord: vec2<f32>) -> vec3<f32> {
    let uv = frag_coord / U.resolution.xy;
    let t = U.time;

    // Classic summed-sine plasma.
    var v = 0.0;
    v += sin((uv.x * 10.0) + t);
    v += sin((uv.y * 10.0 + t) * 0.5);
    v += sin((uv.x * 10.0 + uv.y * 10.0 + t) * 0.5);
    let cx = uv.x + 0.5 * sin(t * 0.2);
    let cy = uv.y + 0.5 * cos(t * 0.3);
    v += sin(sqrt(cx * cx + cy * cy) * 20.0 + t);
    v = v * 0.5;

    return vec3<f32>(
        sin(v * 3.14159),
        sin(v * 3.14159 + 2.09440),
        sin(v * 3.14159 + 4.18879),
    ) * 0.5 + vec3<f32>(0.5);
}
// ===========================================================================
fn sdCappedCylinder(p: vec3<f32>, h: f32, r: f32) -> f32 {
    let d = abs(vec2<f32>(length(p.xz), p.y)) - vec2<f32>(r, h);
    return min(max(d.x, d.y), 0.0) + length(max(d, vec2<f32>(0.0)));
}

fn sdCapsule(p: vec3<f32>, a: vec3<f32>, b: vec3<f32>, r: f32) -> f32 {
    let pa = p - a;
    let ba = b - a;
    let h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
    return length(pa - ba * h) - r;
}

fn smin(a: f32, b: f32, k: f32) -> f32 {
    let h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
    return mix(b, a, h) - k * h * (1.0 - h);
}

fn map_knight(p: vec3<f32>) -> f32 {
    let base = sdCappedCylinder(p - vec3<f32>(0.0, -0.8, 0.0), 0.15, 0.65);
    let collar = sdCappedCylinder(p - vec3<f32>(0.0, -0.55, 0.0), 0.1, 0.5);
    var d = smin(base, collar, 0.08);

    let neck = sdCapsule(p, vec3<f32>(0.0, -0.5, 0.05), vec3<f32>(0.0, 0.45, 0.1), 0.32);
    d = smin(d, neck, 0.15);

    let head = sdCapsule(p, vec3<f32>(0.0, 0.45, 0.1), vec3<f32>(0.0, 0.25, 0.45), 0.22);
    d = smin(d, head, 0.12);

    let p_ear = vec3<f32>(abs(p.x), p.y, p.z);
    let ear = sdCapsule(p_ear, vec3<f32>(0.14, 0.55, 0.15), vec3<f32>(0.16, 0.85, 0.22), 0.07);
    
    return smin(d, ear, 0.05);
}

fn calc_normal(p: vec3<f32>) -> vec3<f32> {
    let e = vec2<f32>(0.001, 0.0);
    return normalize(vec3<f32>(
        map_knight(p + e.xyy) - map_knight(p - e.xyy),
        map_knight(p + e.yxy) - map_knight(p - e.yxy),
        map_knight(p + e.yyx) - map_knight(p - e.yyx)
    ));
}

@fragment
fn fs_main(@builtin(position) frag: vec4<f32>) -> @location(0) vec4<f32> {
    // @builtin(position) is top-left origin; flip Y to bottom-left.
    let frag_coord = vec2<f32>(frag.x, U.resolution.y - frag.y);

    let uv = -(frag_coord - 0.5 * U.resolution.xy) / U.resolution.y;
    let ro = vec3<f32>(0.0, 0.2, 4.6);
    let rd = normalize(vec3<f32>(uv.x, -uv.y, -1.2));
    var t = 0.0;
    
    for (var i=0; i<96; i++) {
        let d = map_knight(ro + rd * t);
        if (d < 0.001 || t > 10.0) { break; }
        t += d;
    }

    var col = vec3<f32>(0.10, 0.12, 0.16);
    if (t < 10.0) {
        let p = ro + rd * t;
        let n = calc_normal(p);
        let light_dir = normalize(vec3<f32>(0.6, 0.8, 0.7));
        let diff = max(dot(n, light_dir), 0.0);
        let spec = pow(max(dot(reflect(-light_dir, n), -rd), 0.0), 32.0);
        let ivory = vec3<f32>(0.93, 0.89, 0.80);
        col = ivory * (0.2 + 0.8 * diff) + vec3<f32>(0.35) * spec;
    }
        
    return vec4<f32>(col, 1.0);
}
"""


def main() raises:
    print("=== wgpu-mojo: plasma (fullscreen fragment shader) ===")
    var instance = Instance()
    var adapter = instance.request_adapter()
    var device = adapter.request_device()
    var canvas = RenderCanvas(adapter, device, WIN_W, WIN_H, "wgpu-mojo · plasma")

    # Uniform buffer: 12 × f32 = 48 bytes (std140-safe layout).
    var uniforms = device.create_buffer(
        UInt64(48),
        WGPUBufferUsage.UNIFORM | WGPUBufferUsage.COPY_DST,
        label="plasma_uniforms",
    )

    var bgl = device.create_bind_group_layout(
        [BGL.buffer_uniform(UInt32(0), WGPUShaderStage.FRAGMENT.value)],
        "plasma_bgl",
    )
    var pl = device.create_pipeline_layout(bgl, "plasma_pl")
    var shader = device.create_shader_module_wgsl(PLASMA_WGSL, "plasma")
    var pipeline = device.create_render_pipeline(
        shader, "vs_main", "fs_main", canvas.surface_format(), pl,
        label="plasma_pipeline",
    )
    _ = shader^
    _ = pl^

    var bind_group = device.create_bind_group(
        bgl,
        [
            WGPUBindGroupEntry(
                null_opaque(), UInt32(0), uniforms.handle().raw,
                UInt64(0), WGPU_WHOLE_SIZE, null_opaque(), null_opaque(),
            )
        ],
        "plasma_bg",
    )
    _ = bgl^

    print("Rendering — close the window to quit.")
    var start_time = io.time.perf_counter()
    var frame_idx = 0

    while canvas.is_open():
        var elapsed = Float32((io.time.perf_counter() - start_time) / 1e9)
        canvas.poll()

        var frame = canvas.next_frame()
        if not frame.is_renderable():
            continue

        # resolution, time, mouse(0), frame, padding → 48 bytes.
        var u = List[Float32](capacity=12)
        u.append(Float32(WIN_W))   # resolution.x
        u.append(Float32(WIN_H))   # resolution.y
        u.append(Float32(1.0))     # resolution.z
        u.append(elapsed)          # time
        u.append(Float32(0.0))     # mouse.x
        u.append(Float32(0.0))     # mouse.y
        u.append(Float32(0.0))     # mouse.z
        u.append(Float32(0.0))     # mouse.w
        u.append(Float32(frame_idx))  # frame
        u.append(Float32(0.0))
        u.append(Float32(0.0))
        u.append(Float32(0.0))
        device.queue_write_data(uniforms, UInt64(0), u)

        var enc = device.create_command_encoder("plasma_frame")
        var rpass = enc.begin_surface_clear_pass(
            frame.texture,
            WGPUColor(Float64(0), Float64(0), Float64(0), Float64(1)),
            "plasma_pass",
        )
        rpass.set_pipeline(pipeline)
        rpass.set_bind_group(UInt32(0), bind_group)
        rpass.draw(UInt32(6), UInt32(1), UInt32(0), UInt32(0))
        rpass^.end()

        device.queue_submit(enc^.finish())
        canvas.present()
        frame_idx += 1

    print("Done. Rendered", frame_idx, "frames.")
    _ = uniforms^
