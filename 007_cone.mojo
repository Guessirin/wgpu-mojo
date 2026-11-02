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
fn sdCone(p: vec3<f32>, c: vec2<f32>, h: f32) -> f32 {
    let q = vec2<f32>(length(p.xz), p.y);
    let d = max(dot(c.xy, q), -p.y - h);
    let e = max(q.y - h, 0.0);
    return max(d, e);
}

fn rotate(p: vec3<f32>, angleX: f32, angleY: f32) -> vec3<f32> {
    let sX = sin(angleX); let cX = cos(angleX);
    let sY = sin(angleY); let cY = cos(angleY);

    var r = p;
    r = vec3<f32>(r.x * cY - r.z * sY, r.y, r.x * sY + r.z * cY);
    r = vec3<f32>(r.x, r.y * cX - r.z * sX, r.y * sX + r.z * cX);
    return r;
}

fn shade(frag_coord: vec2<f32>) -> vec3<f32> {
    let uv = (frag_coord * 2.0 - U.resolution.xy) / U.resolution.y;

    let ro = vec3<f32>(0.0, 1.0, 8.5);
    let rd = normalize(vec3<f32>(uv, -1.5));
 
    let coneAngle = vec2<f32>(0.5, 0.866);
    let coneHeight = 1.5;

    var t = 0.0;
    var hit = false;
    var p = vec3<f32>(0.0);

    for (var i=0; i<80; i++) {
	p = ro + rd * t;

	let rotatedP = rotate(p, U.time * 0.5, U.time * 0.7);

	let conePos = rotatedP - vec3<f32>(0.0, -0.5, 0.0);

	let d = sdCone(conePos, coneAngle, coneHeight);
	if (d < 0.001) {
	    hit = true;
	    break;
	}
	t += d;
	if (t > 10.0) { break; }
    }

    var color = vec3<f32>(0.08, 0.08, 0.12);

    if (hit) {
	let eps = 0.001;
	let cAngle = coneAngle;
	let cH = coneHeight;

	let rp = rotate(p, U.time * 0.5, U.time * 0.7) - vec3<f32>(0.0, -0.5, 0.0);
	let n = normalize(vec3<f32>(
	    sdCone(rp + vec3<f32>(eps, 0.0, 0.0), cAngle, cH) - sdCone(rp - vec3<f32>(eps, 0.0, 0.0), cAngle, cH),
	    sdCone(rp + vec3<f32>(0.0, eps, 0.0), cAngle, cH) - sdCone(rp - vec3<f32>(0.0, eps, 0.0), cAngle, cH),
	    sdCone(rp + vec3<f32>(0.0, 0.0, eps), cAngle, cH) - sdCone(rp - vec3<f32>(0.0, 0.0, eps), cAngle, cH)
	));

	let lightDir = normalize(vec3<f32>(1.0, 2.0, 1.0));
	let diff = max(dot(n, lightDir), 0.0);

	let baseColor = 0.5 + 0.5 * sin(vec3<f32>(0.0, 2.0, 4.0) + U.time + p.y);
	color = baseColor * (diff + 0.15);
    }

    return color;
}
// ===========================================================================

@fragment
fn fs_main(@builtin(position) frag: vec4<f32>) -> @location(0) vec4<f32> {
    // @builtin(position) is top-left origin; flip Y to bottom-left.
    let frag_coord = vec2<f32>(frag.x, U.resolution.y - frag.y);
    return vec4<f32>(shade(frag_coord), 1.0);
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
