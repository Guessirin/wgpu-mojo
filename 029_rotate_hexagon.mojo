from time import perf_counter_ns
from memory import UnsafePointer
from wgpu import request_adapter
from wgpu.rendercanvas import RenderCanvas
from wgpu.enums import BufferUsage, ShaderStage, PrimitiveTopology, TextureFormat

@register_passable("trivial")
struct Uniforms:
    var width: Float32
    var height: Float32
    var time: Float32
    var _pad: Float32

def main() raises:
    var width: UInt32 = 800
    var height: UInt32 = 600

    var inst = request_adapter()
    var device = inst.request_device()
    var canvas = RenderCanvas(inst, device, Int(width), Int(height), "wgpu-mojo: 3D Octagon SDF")

    # Load WGSL source from file or inline string
    var wgsl_code = open("octagon_3d.wgsl", "r").read()
    var shader = device.create_shader_module_wgsl(wgsl_code, "octagon_3d")

    # Create 16-byte uniform buffer for resolution and elapsed time
    var uniform_buf = device.create_buffer(
        size=16,
        usage=BufferUsage.UNIFORM | BufferUsage.COPY_DST,
        label="uniforms"
    )

    var bind_group_layout = device.create_bind_group_layout_uniform(
        binding=0,
        visibility=ShaderStage.FRAGMENT
    )
    var bind_group = device.create_bind_group(
        layout=bind_group_layout,
        binding=0,
        buffer=uniform_buf,
        offset=0,
        size=16
    )

    var pipeline_layout = device.create_pipeline_layout(bind_group_layout)
    var pipeline = device.create_render_pipeline(
        layout=pipeline_layout,
        shader=shader,
        vs_entry="vs_main",
        fs_entry="fs_main",
        target_format=canvas.format(),
        topology=PrimitiveTopology.TRIANGLE_LIST
    )

    var start_ns = perf_counter_ns()
    var u_data = Uniforms(width=Float32(width), height=Float32(height), time=0.0, _pad=0.0)

    while canvas.is_open():
        canvas.poll()

        var elapsed = Float32(perf_counter_ns() - start_ns) / 1_000_000_000.0
        u_data.time = elapsed
        device.queue_write_buffer(uniform_buf, 0, UnsafePointer.address_of(u_data).bitcast[UInt8](), 16)

        var frame = canvas.next_frame()
        var enc = device.create_command_encoder("frame_enc")
        var rpass = enc.begin_render_pass(frame.view(), clear_color=(0.08, 0.09, 0.12, 1.0))

        rpass.set_pipeline(pipeline)
        rpass.set_bind_group(0, bind_group)
        rpass.draw(3, 1, 0, 0) # Draws the 3-vertex fullscreen triangle
        rpass^.end()

        device.queue_submit(enc^.finish())
        canvas.present()

    # Keep resources alive until loop exits
    _ = pipeline^
    _ = bind_group^
    _ = uniform_buf^
