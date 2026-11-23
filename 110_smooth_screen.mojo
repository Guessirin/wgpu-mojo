from math import sin, cos
from memory import UnsafePointer
from wgpu.instance import Instance
from wgpu.rendercanvas import RenderCanvas
from wgpu._ffi.structs import WGPUColor
from wgpu import WGPUBufferUsage, WGPUTextureFormat, WGPUTextureUsage

comptime SHADER_WGSL = """
struct Uniforms {
    angle: f32,
    aspect: f32,
};

@group(0) @binding(0) var<uniform> u: Uniforms;

struct VertexOutput {
    @builtin(position) pos: vec4<f32>,
    @location(0) color: vec3<f32>,
};

@vertex
fn vs_main(@builtin(vertex_index) idx: u32) -> VertexOutput {
    // 36 vertices forming a 3D cube
    var positions = array<vec3<f32>, 8>(
        vec3(-0.5, -0.5,  0.5), vec3( 0.5, -0.5,  0.5),
        vec3( 0.5,  0.5,  0.5), vec3(-0.5,  0.5,  0.5),
        vec3(-0.5, -0.5, -0.5), vec3( 0.5, -0.5, -0.5),
        vec3( 0.5,  0.5, -0.5), vec3(-0.5,  0.5, -0.5)
    );
    var indices = array<u32, 36>(
        0, 1, 2, 2, 3, 0, // Front
        1, 5, 6, 6, 2, 1, // Right
        5, 4, 7, 7, 6, 5, // Back
        4, 0, 3, 3, 7, 4, // Left
        3, 2, 6, 6, 7, 3, // Top
        4, 5, 1, 1, 0, 4  // Bottom
    );

    let p = positions[indices[idx]];

    // Rotate smoothly around Y and X axes
    let c = cos(u.angle);
    let s = sin(u.angle);
    let rx = vec3<f32>(p.x * c - p.z * s, p.y, p.x * s + p.z * c);
    let ry = vec3<f32>(rx.x, rx.y * c - rx.z * s, rx.y * s + rx.z * c);

    // Simple perspective projection
    let z_offset = ry.z + 2.2;
    let fov = 1.5;
    var out: VertexOutput;
    out.pos = vec4<f32>(
        (ry.x * fov) / u.aspect,
        ry.y * fov,
        ry.z * 0.1 + 0.5,
        z_offset
    );
    out.color = p + 0.5;
    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    return vec4<f32>(in.color, 1.0);
}
"""

def main() raises:
    var instance = Instance()
    var adapter = instance.request_adapter()
    var device = adapter.request_device()
    var canvas = RenderCanvas(adapter, device, 800, 600, "wgpu-mojo 3D")

    # 1. Uniform buffer (16-byte aligned: angle + aspect + 8 bytes padding)
    var uniform_buf = device.create_buffer(
        size=16,
        usage=WGPUBufferUsage.UNIFORM | WGPUBufferUsage.COPY_DST,
        label="uniforms"
    )

    # 2. Depth texture for proper 3D occlusion
    var depth_tex = device.create_texture(
        width=800,
        height=600,
        format=WGPUTextureFormat.Depth24Plus,
        usage=WGPUTextureUsage.RenderAttachment,
        label="depth"
    )
    var depth_view = depth_tex.create_view()

    # 3. Bind group & pipeline setup
    var shader = device.create_shader_module_wgsl(SHADER_WGSL, "cube_shader")
    var bgl = device.create_uniform_bind_group_layout(binding=0)
    var bind_group = device.create_uniform_bind_group(bgl, uniform_buf, size=16)
    var pl = device.create_pipeline_layout([bgl.handle()], "cube_pl")

    var pipeline = device.create_render_pipeline(
        shader,
        "vs_main",
        "fs_main",
        canvas.surface_format(),
        pl,
        depth_format=WGPUTextureFormat.Depth24Plus
    )

    # Pin resources that must outlive pipeline construction
    _ = pl^
    _ = bgl^
    _ = shader^

    var angle: Float32 = 0.0
    var u_data = InlineArray[Float32, 4](0.0, 800.0 / 600.0, 0.0, 0.0)

    # 4. Smooth vsync render loop
    while canvas.is_open():
        canvas.poll()
        var frame = canvas.next_frame()
        if not frame.is_renderable():
            continue

        # Update rotation and upload to GPU queue
        angle += 0.016
        u_data[0] = angle
        device.queue_write_buffer(uniform_buf, 0, UnsafePointer.address_of(u_data).bitcast[UInt8](), 16)

        var enc = device.create_command_encoder("frame")
        var rpass = enc.begin_render_pass(
            color_view=frame.texture,
            clear_color=WGPUColor(0.08, 0.09, 0.12, 1.0),
            depth_view=depth_view
        )
        rpass.set_pipeline(pipeline)
        rpass.set_bind_group(0, bind_group)
        rpass.draw(36, 1, 0, 0)
        rpass^.end()

        device.queue_submit(enc^.finish())
        canvas.present()

    # Pin GPU resources until loop exits
    _ = bind_group^
    _ = pipeline^
    _ = depth_view^
    _ = depth_tex^
    _ = uniform_buf^

