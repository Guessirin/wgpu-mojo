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

from wgpu import *
from wgpu.device import Device
from wgpu.rendercanvas import RenderCanvas
from wgpu.rendercanvas.glfw import (
    GLFW_MOUSE_BUTTON_LEFT,
)
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
    mouse: vec2<f32>,
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

fn sdCircle(p: vec2<f32>, r: f32) -> f32 {
    return length(p) - r;
}

fn sdBox(p: vec2<f32>, b: vec2<f32>) -> f32 {
    let d = abs(p) - b;
    return length(max(d, vec2<f32>(0.0))) + min(max(d.x, d.y), 0.0);
}

fn shade(frag_coord: vec2<f32>) -> vec3<f32> {

    let uv = (frag_coord * 2.0 - U.resolution.xy) / U.resolution.y;
    let mouse_uv = (U.mouse * 2.0 - U.resolution.xy) / U.resolution.y;

    let t = U.time * 1.5;
    var plasma = sin(uv.x * 4.0 + t) + sin(uv.y * 4.0 - t);
    plasma += sin(10.0 * (uv.x + sin(t / 2.0) + uv.y * cos(t / 3.0)) + t);
    let r_bg = vec3<f32>(0.5 + 0.5 * sin(plasma), 0.2 + 0.3 * cos(plasma), 0.6 + 0.4 * sin(plasma + 2.0));

    let circle_center = vec2<f32>(-0.5, 0.2 * sin(U.time));
    let circle_radius = 0.25;

    let mouse_to_circle = sdCircle(mouse_uv - circle_center, circle_radius);
    let is_circle_picked = mouse_to_circle < 0.0;

    let dist_circle = sdCircle(uv - circle_center, circle_radius);
    let circle_color = select(vec3<f32>(0.1, 0.8, 0.4), vec3<f32>(0.9, 0.2, 0.2), is_circle_picked);

    let box_center = vec2<f32>(0.5, 0.0);
    let box_size = vec2<f32>(0.2, 0.2);

    let mouse_to_box = sdBox(mouse_uv - box_center, box_size);
    let is_box_picked = mouse_to_box < 0.0;

    let dist_box = sdBox(uv - box_center, box_size);
    let box_color = select(vec3<f32>(0.9, 0.7, 0.1), vec3<f32>(1.0, 0.4, 0.9), is_box_picked);

    var final_color = r_bg;

    let edge_smoothing = 1.5 / U.resolution.y;

    let circle_mask = smoothstep(edge_smoothing, 0.0, dist_circle);
    
    final_color = mix(final_color, circle_color, circle_mask);
    
    let box_mask = smoothstep(edge_smoothing, 0.0, dist_box);
 
    final_color = mix(final_color, box_color, box_mask);
    

    return final_color;
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

        if canvas.input.is_mouse_button_just_pressed(GLFW_MOUSE_BUTTON_LEFT):
            print(
                "[mouse] Left click at",
                canvas.input.mouse_x,
                canvas.input.mouse_y,
            )
           

#        u.mouse.x = canvas.input.mouse_x;
#        u.mouse.y = canvas.input.mouse_y;

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
