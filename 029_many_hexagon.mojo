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
fn hex_coords(p: vec2<f32>) -> vec4<f32> {
    let r = vec2<f32>(1.0, 1.7320508);
    let h = r * 0.5;
    let a = (p - r * floor(p / r)) - h;
    let b = ((p - h) - r * floor((p - h) / r)) - h;
    let gv = select(b, a, dot(a, a) < dot(b, b));
    let id = p - gv;
    return vec4<f32>(gv, id);
}

fn sd_hex_prism(p: vec3<f32>, h: vec2<f32>) -> f32 {
    let k = vec3<f32>(-0.8660254, 0.5, 0.57735027);
    var q = abs(p);
    q = vec3<f32>(q.xy - 2.0 * min(dot(k.xy, q.xy), 0.0) * k.xy, q.z);
    let d = vec2<f32>(
        length(q.xy - vec2<f32>(clamp(q.x, -k.z * h.x, k.z * h.x), h.x)) * sign(q.y - h.x), q.z - h.y
    );
    return min(max(d.x, d.y), 0.0) + length(max(d, vec2<f32>(0.0)));
}

fn plasma_wave(p: vec2<f32>, t: f32) -> f32 {
    let v1 = sin(p.x * 1.4 + t);
    let v2 = sin(p.y * 1.4 + t * 1.2);
    let v3 = sin((p.x + p.y) * 1.1 - t * 0.8);
    let v4 = sin(length(p) * 1.8 - t * 1.5);
    return (v1 + v2 + v3 + v4) * 0.25;
}

fn plasma_color(t: f32) -> vec3<f32> {
    let a = vec3<f32>(0.5, 0.5, 0.5);
    let b = vec3<f32>(0.5, 0.5, 0.5);
    let c = vec3<f32>(1.0, 1.0, 1.0);
    let d = vec3<f32>(0.00, 0.33, 0.67);
    return a + b * cos(6.28318 * (c * t + d));
}

fn map_scene(p: vec3<f32>) -> vec2<f32> {
    let hex = hex_coords(p.xz * 1.2);
    let cell_id = hex.zw;
    let wave = plasma_wave(cell_id, U.time);
    let pillar_height = 0.6 + 0.55 * wave;

    let local_p = vec3<f32>(hex.x, hex.y, p.y);
    let d = sd_hex_prism(local_p, vec2<f32>(0.42, pillar_height));
    return vec2<f32>(d, wave);
}

fn calc_normal(p: vec3<f32>) -> vec3<f32> {
    let e = vec2<f32>(0.002, 0.0);
    return normalize(vec3<f32>(
        map_scene(p + e.xyy).x - map_scene(p - e.xyy).x,
        map_scene(p + e.yxy).x - map_scene(p - e.yxy).x,
        map_scene(p + e.yyx).x - map_scene(p - e.yyx).x
    ));
}

    
@fragment
fn fs_main(@builtin(position) frag: vec4<f32>) -> @location(0) vec4<f32> {
    // @builtin(position) is top-left origin; flip Y to bottom-left.
    let frag_coord = vec2<f32>(frag.x, U.resolution.y - frag.y);

    //let uv = (frag_coord * 2.0 - U.resolution.xy) / min(U.resolution.x, U.resolution.y);
    let aspect = U.resolution.x / U.resolution.y;
    //let ndc = (frag_coord.x * 2.0 - 1.0) * aspect, 1.0 - frag_coord.y * 2.0;
    let ndc = (frag_coord * 2.0 - U.resolution.xy) / min(U.resolution.x, U.resolution.y);
    let angle = U.time * 0.25;
    let ro = vec3<f32>(sin(angle) * 4.5, 3.2, cos(angle) * 4.5);
    let target1 = vec3<f32>(0.0, 0.2, 0.0);

    let forward = normalize(target1 - ro);
    let right = normalize(cross(vec3<f32>(0.0, 1.0, 0.0), forward));
    let up = cross(forward, right);
    let rd = normalize(forward * 1.6 + right * ndc.x + up * ndc.y);

    var t = 0.0;
    var hit_wave = 0.0;
    var hit = false;
    for (var i=0; i<80; i++) {
        let p = ro + rd * t;
        let res = map_scene(p);
        if (res.x < 0.002) {
            hit = true;
            hit_wave = res.y;
            break;
        }
        t += res.x * 0.7;
        if (t > 25.0) { break; }
    }

    var col = vec3<f32>(0.03, 0.03, 0.06);

    if (hit) {
        let p = ro + rd * t;
        let n = calc_normal(p);
        let lightDir = normalize(vec3<f32>(0.6, 0.9, 0.4));
        let diff = max(dot(n, lightDir), 0.15);
        let rim = pow(1.0 - max(dot(n, -rd), 0.0), 3.0);

        let base_col = plasma_color(hit_wave * 0.8 + U.time * 0.15);
        col = base_col * diff + rim * vec3<f32>(0.4, 0.8, 1.0) * 0.5;
        col = mix(col, vec3<f32>(0.03, 0.03, 0.06), smoothstep(6.0, 22.0, t));
    }

    return vec4<f32>(pow(col, vec3<f32>(0.4545)), 1.0);
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
