struct Uniforms {
    resolution: vec2<f32>,
    time: f32,
    _pad: f32,
};

@group(0) @binding(0)
var<uniform> u: Uniforms;

struct VertexOut {
    @builtin(position) pos: vec4<f32>,
};

@vertex
fn vs_main(@builtin(vertex_index) idx: u32) -> VertexOut {
    // Fullscreen triangle covering the entire viewport
    var positions = array<vec2<f32>, 3>(
        vec2<f32>(-1.0, -1.0),
        vec2<f32>( 3.0, -1.0),
        vec2<f32>(-1.0,  3.0)
    );
    var out: VertexOut;
    out.pos = vec4<f32>(positions[idx], 0.0, 1.0);
    return out;
}

// 2D Regular Octagon SDF (Inigo Quilez)
fn sdOctagon(p_in: vec2<f32>, r: f32) -> f32 {
    let k = vec3<f32>(-0.9238795325, 0.3826834323, 0.4142135623);
    var p = abs(p_in);
    p -= 2.0 * min(dot(vec2<f32>( k.x, k.y), p), 0.0) * vec2<f32>( k.x, k.y);
    p -= 2.0 * min(dot(vec2<f32>(-k.x, k.y), p), 0.0) * vec2<f32>(-k.x, k.y);
    p -= vec2<f32>(clamp(p.x, -k.z * r, k.z * r), r);
    return length(p) * sign(p.y);
}

// Extrude a 2D SDF into a 3D prism along the Z-axis
fn sdOctagon3D(p: vec3<f32>, r: f32, half_height: f32) -> f32 {
    let d = sdOctagon(p.xy, r);
    let w = vec2<f32>(d, abs(p.z) - half_height);
    return min(max(w.x, w.y), 0.0) + length(max(w, vec2<f32>(0.0)));
}

fn rotateY(p: vec3<f32>, angle: f32) -> vec3<f32> {
    let c = cos(angle);
    let s = sin(angle);
    return vec3<f32>(c * p.x + s * p.z, p.y, -s * p.x + c * p.z);
}

fn rotateX(p: vec3<f32>, angle: f32) -> vec3<f32> {
    let c = cos(angle);
    let s = sin(angle);
    return vec3<f32>(p.x, c * p.y - s * p.z, s * p.y + c * p.z);
}

fn map(p: vec3<f32>) -> f32 {
    var q = rotateY(p, u.time * 0.8);
    q = rotateX(q, u.time * 0.5);
    // Radius = 0.8, Half-depth = 0.25, slight bevel (-0.03)
    return sdOctagon3D(q, 0.8, 0.25) - 0.03;
}

fn calcNormal(p: vec3<f32>) -> vec3<f32> {
    let e = vec2<f32>(0.001, 0.0);
    return normalize(vec3<f32>(
        map(p + e.xyy) - map(p - e.xyy),
        map(p + e.yxy) - map(p - e.yxy),
        map(p + e.yyx) - map(p - e.yyx)
    ));
}

@fragment
fn fs_main(@builtin(position) frag_coord: vec4<f32>) -> @location(0) vec4<f32> {
    let uv = (frag_coord.xy - 0.5 * u.resolution) / u.resolution.y;
    let ro = vec3<f32>(0.0, 0.0, 3.0);
    let rd = normalize(vec3<f32>(uv.x, -uv.y, -1.5));

    var t = 0.0;
    var hit = false;
    for (var i = 0; i < 64; i++) {
        let p = ro + rd * t;
        let d = map(p);
        if (d < 0.001) {
            hit = true;
            break;
        }
        t += d;
        if (t > 20.0) {
            break;
        }
    }

    if (hit) {
        let p = ro + rd * t;
        let n = calcNormal(p);
        let light_dir = normalize(vec3<f32>(0.6, 0.8, 1.0));
        let diff = max(dot(n, light_dir), 0.15);
        let base_color = vec3<f32>(0.2, 0.7, 0.9);
        return vec4<f32>(base_color * diff, 1.0);
    }

    return vec4<f32>(0.08, 0.09, 0.12, 1.0);
}

