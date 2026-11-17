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
fn sdBox(p: vec3<f32>, b: vec3<f32>) -> f32 {
    let q = abs(p) - b;
    return length(max(q, vec3<f32>(0.0))) + min(max(q.x, max(q.y, q.z)), 0.0);
}

fn sdPiece(p: vec3<f32>) -> f32 {
    let base = sdBox(p - vec3<f32>(0.0, 0.12, 0.0), vec3<f32>(0.28, 0.12, 0.28)) - 0.03;
    let body = sdBox(p - vec3<f32>(0.0, 0.45, 0.0), vec3<f32>(0.16, 0.28, 0.16)) - 0.02;
    let head = sdBox(p - vec3<f32>(0.0, 0.78, 0.0), vec3<f32>(0.22, 0.09, 0.22)) - 0.02;
    return min(base, min(body, head));
}

fn mapScene(p: vec3<f32>) -> vec2<f32> {
    let border = sdBox(p - vec3<f32>(0.0, -0.22, 0.0), vec3<f32>(0.4, 0.0, 0.4)) - 0.05;
    let board = sdBox(p - vec3<f32>(0.0, -0.1, 0.0), vec3<f32>(4.0, 0.1, 4.0));
    var res = vec2<f32>(border, 1.0);
    if (board < res.x) {
        res = vec2<f32>(board, 2.0);
    }

    let cell = floor(p.xz);
    let in_board = all(cell >= vec2<f32>(-4.0)) && all(cell < vec2<f32>(4.0));
    let is_piece_rank = (cell.y == -4.0 || cell.y == -3.0 || cell.y == 2.0 || cell.y == 3.0);
    if (in_board && is_piece_rank) {
        let local_xz = fract(p.xz) - 0.5;
        let d_piece = sdPiece(vec3<f32>(local_xz.x, p.y, local_xz.y));
        let mat_id = select(3.0, 4.0, cell.y > 0.0);
        if (d_piece < res.x) {
            res = vec2<f32>(d_piece, mat_id);
        }
    }
    return res;
}


fn calcNormal(p: vec3<f32>) -> vec3<f32> {
    let e = vec2<f32>(0.001, 0.0);
    return normalize(vec3<f32>(
        mapScene(p + e.xyy).x - mapScene(p - e.xyy).x,
        mapScene(p + e.yxy).x - mapScene(p - e.yxy).x,
        mapScene(p + e.yyx).x - mapScene(p - e.yyx).x
    ));
}

@fragment
fn fs_main(@builtin(position) frag: vec4<f32>) -> @location(0) vec4<f32> {
    let frag_coord = vec2<f32>(frag.x, U.resolution.y - frag.y);
    let uv = (frag_coord - 0.5 * U.resolution.xy) / U.resolution.y;

    let angle = U.time * 0.35;
    let ro = vec3<f32>(sin(angle) * 9.5, 6.5, cos(angle) * 9.5);
    let target1 = vec3<f32>(0.0, 0.2, 0.0);
    let fwd = normalize(target1 - ro);
    let right = normalize(cross(fwd, vec3<f32>(0.0, 1.0, 0.0)));
    let up = cross(right, fwd);
    let rd = normalize(fwd * 1.6 + right * uv.x + up * uv.y);

    var t = 0.0;
    var mat = 0.0;
    for (var i=0; i<96; i++) {
        let hit = mapScene(ro + rd * t);
        if (hit.x < 0.001) {
            mat = hit.y;
            break;
        }
        t += hit.x;
        if (t > 30.0) { break; }
    }

    var col = mix(vec3<f32>(0.08, 0.10, 0.14), vec3<f32>(0.18, 0.22, 0.30), uv.y * 0.5 + 0.5);

    if (mat > 0.0) {
        let pos = ro + rd * t;
        let nor = calcNormal(pos);
        let light_dir = normalize(vec3<f32>(0.6, 1.0, 0.4));
        let diff = max(dot(nor, light_dir), 0.0);

        var albedo = vec3<f32>(0.25, 0.14, 0.08);
        if (mat==2.0) {
            let sq = floor(pos.xz);
            let checker = abs((sq.x + sq.y) % 2.0);
            albedo = mix(vec3<f32>(0.15, 0.16, 0.19), vec3<f32>(0.88, 0.85, 0.78), checker);
        } else if (mat == 3.0) {
            albedo = vec3<f32>(0.92, 0.90, 0.85);
        } else if (mat == 4.0) {
            albedo = vec3<f32>(0.12, 0.13, 0.15);
        }
        col = albedo * (diff * 0.85 + 0.2);
    }
    return vec4<f32>(pow(col, vec3<f32>(1.0/2.2)), 1.0);
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
