//! Encodes one mesh paint, including its exact curved boundary, as a PDF page.
//! No fonts, Typst frames, scene traversal, or lighting computations live here.
use pdf_writer::{
    types::MaskType, writers::StreamShadingType, Content, Filter, Finish, Name, Pdf, Rect, Ref,
};

#[repr(C)]
#[derive(Clone, Copy)]
pub struct HuakMeshVertex {
    pub x: f64,
    pub y: f64,
    pub r: f64,
    pub g: f64,
    pub b: f64,
    pub a: f64,
}
#[repr(C)]
pub struct HuakMeshClip {
    pub kind: u32,
    pub points: [f64; 6],
}
#[repr(C)]
pub struct HuakMeshPdf {
    pub vertices: *const HuakMeshVertex,
    pub vertex_count: usize,
    pub triangles: *const u32,
    pub triangle_count: usize,
    pub clip: *const HuakMeshClip,
    pub clip_count: usize,
    /// Minimum x/y and positive width/height, in the original coordinate system.
    pub bounds: [f64; 4],
    pub evenodd: bool,
}
#[repr(C)]
#[derive(Default)]
pub struct HuakMeshBuffer {
    pub data: *mut u8,
    pub len: usize,
    /// Kept for the matching Rust deallocation; callers must not change it.
    pub capacity: usize,
}

/// Borrow inputs for this call only. On success, the output owns its allocation.
/// Return 0 on success, 1 for invalid input, 2 for a contained Rust panic.
///
/// # Safety
/// All pointers must be aligned, valid for their lengths, and non-null when nonempty.
/// The output slot must not overlap the inputs or hold an unreleased buffer.
#[no_mangle]
pub unsafe extern "C" fn huak_mesh_pdf(
    input: *const HuakMeshPdf,
    output: *mut HuakMeshBuffer,
) -> u32 {
    if output.is_null() {
        return 1;
    }
    output.write(HuakMeshBuffer::default());
    if input.is_null() {
        return 1;
    }
    match std::panic::catch_unwind(|| encode(&*input)) {
        Ok(Some(bytes)) => {
            let mut bytes = std::mem::ManuallyDrop::new(bytes);
            output.write(HuakMeshBuffer {
                data: bytes.as_mut_ptr(),
                len: bytes.len(),
                capacity: bytes.capacity(),
            });
            0
        }
        Ok(None) => 1,
        Err(_) => 2,
    }
}

/// Release a successful output exactly once, using this same library.
///
/// # Safety
/// The buffer must be an unchanged successful result or a zero-initialized buffer.
#[no_mangle]
pub unsafe extern "C" fn huak_mesh_pdf_free(buffer: HuakMeshBuffer) {
    if !buffer.data.is_null() {
        drop(Vec::from_raw_parts(
            buffer.data,
            buffer.len,
            buffer.capacity,
        ));
    }
}

unsafe fn encode(input: &HuakMeshPdf) -> Option<Vec<u8>> {
    if input.vertex_count < 3
        || input.triangle_count == 0
        || input.clip_count == 0
        || input.vertices.is_null()
        || input.triangles.is_null()
        || input.clip.is_null()
    {
        return None;
    }
    let [x, y, width, height] = input.bounds;
    if !input.bounds.iter().all(|v| v.is_finite()) || width <= 0.0 || height <= 0.0 {
        return None;
    }
    let vertices = std::slice::from_raw_parts(input.vertices, input.vertex_count);
    let triangles =
        std::slice::from_raw_parts(input.triangles, input.triangle_count.checked_mul(3)?);
    let clip = std::slice::from_raw_parts(input.clip, input.clip_count);
    let mut rgb = Vec::with_capacity(triangles.len().checked_mul(15)?);
    let transparent = vertices.iter().any(|v| v.a != 1.0);
    let mut alpha = Vec::with_capacity(if transparent {
        triangles.len().checked_mul(11)?
    } else {
        0
    });
    for triangle in triangles.chunks_exact(3) {
        for index in triangle {
            let v = vertices.get(*index as usize)?;
            let coordinates = [(v.x - x) / width, (v.y - y) / height];
            if !coordinates
                .iter()
                .chain([&v.r, &v.g, &v.b, &v.a])
                .all(|v| v.is_finite() && (0.0..=1.0).contains(v))
            {
                return None;
            }
            // Independent triangle records use flag 0; compression recovers shared edges.
            rgb.push(0);
            for coordinate in coordinates {
                rgb.extend_from_slice(
                    &((coordinate * u32::MAX as f64).round() as u32).to_be_bytes(),
                );
            }
            if transparent {
                alpha.extend_from_slice(&rgb[rgb.len() - 9..]);
                alpha.extend_from_slice(&((v.a * u16::MAX as f64).round() as u16).to_be_bytes());
            }
            for component in [v.r, v.g, v.b] {
                rgb.extend_from_slice(
                    &((component * u16::MAX as f64).round() as u16).to_be_bytes(),
                );
            }
        }
    }
    let mut pdf = Pdf::new();
    // Type 4 shading is PDF 1.3; luminosity soft masks require PDF 1.4.
    pdf.set_version(1, 4);
    let [catalog, pages, page, stream, color_mesh, alpha_mesh, mask, state] =
        [1, 2, 3, 4, 5, 6, 7, 8].map(Ref::new);
    pdf.catalog(catalog).pages(pages);
    pdf.pages(pages).kids([page]).count(1);
    {
        let mut page = pdf.page(page);
        page.parent(pages)
            .media_box(Rect::new(0.0, 0.0, 1.0, 1.0))
            .contents(stream);
        let mut resources = page.resources();
        resources.shadings().pair(Name(b"Color"), color_mesh);
        if transparent {
            resources.ext_g_states().pair(Name(b"Alpha"), state);
        }
    }
    shading(&mut pdf, color_mesh, rgb, false);
    if transparent {
        shading(&mut pdf, alpha_mesh, alpha, true);
        let mut content = Content::new();
        content.shading(Name(b"Alpha"));
        let bytes = content.finish();
        let mut form = pdf.form_xobject(mask, &bytes);
        form.bbox(Rect::new(0.0, 0.0, 1.0, 1.0));
        form.resources().shadings().pair(Name(b"Alpha"), alpha_mesh);
        form.group().transparency().color_space().device_gray();
        form.finish();
        pdf.ext_graphics(state)
            .soft_mask()
            .subtype(MaskType::Luminosity)
            .group(mask);
    }
    let mut content = Content::new();
    for segment in clip {
        if !segment.points.iter().all(|v| v.is_finite()) {
            return None;
        }
        let mut p = [0.0; 6];
        let count = match segment.kind {
            0 | 1 => 1,
            2 => 3,
            3 => 0,
            _ => return None,
        };
        for i in 0..count {
            p[2 * i] = ((segment.points[2 * i] - x) / width) as f32;
            p[2 * i + 1] = ((segment.points[2 * i + 1] - y) / height) as f32;
        }
        if !p.iter().all(|v| v.is_finite()) {
            return None;
        }
        match segment.kind {
            0 => {
                content.move_to(p[0], p[1]);
            }
            1 => {
                content.line_to(p[0], p[1]);
            }
            2 => {
                content.cubic_to(p[0], p[1], p[2], p[3], p[4], p[5]);
            }
            3 => {
                content.close_path();
            }
            _ => return None,
        }
    }
    if input.evenodd {
        content.clip_even_odd();
    } else {
        content.clip_nonzero();
    }
    content.end_path();
    if transparent {
        content.set_parameters(Name(b"Alpha"));
    }
    content.shading(Name(b"Color"));
    pdf.stream(stream, &content.finish());
    Some(pdf.finish())
}

fn shading(pdf: &mut Pdf, id: Ref, bytes: Vec<u8>, gray: bool) {
    let compressed = miniz_oxide::deflate::compress_to_vec_zlib(&bytes, 6);
    drop(bytes);
    let mut mesh = pdf.stream_shading(id, &compressed);
    mesh.shading_type(StreamShadingType::FreeformGouraud);
    if gray {
        mesh.color_space().device_gray();
    } else {
        mesh.color_space().device_rgb();
    }
    let decode = [0.0, 1.0, 0.0, 1.0, 0.0, 1.0, 0.0, 1.0, 0.0, 1.0];
    mesh.bits_per_coordinate(32)
        .bits_per_component(16)
        .bits_per_flag(8)
        .decode(decode[..if gray { 6 } else { 10 }].iter().copied())
        .filter(Filter::FlateDecode);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn owned_output_survives_inputs_and_invalid_input_clears_output() {
        let vertices = vec![
            HuakMeshVertex {
                x: 0.0,
                y: 0.0,
                r: 1.0,
                g: 0.0,
                b: 0.0,
                a: 1.0,
            },
            HuakMeshVertex {
                x: 1.0,
                y: 0.0,
                r: 0.0,
                g: 1.0,
                b: 0.0,
                a: 0.5,
            },
            HuakMeshVertex {
                x: 0.0,
                y: 1.0,
                r: 0.0,
                g: 0.0,
                b: 1.0,
                a: 0.0,
            },
        ];
        let triangles = [0, 1, 2];
        let mut clip = [
            HuakMeshClip {
                kind: 0,
                points: [0.0; 6],
            },
            HuakMeshClip {
                kind: 1,
                points: [1.0, 0.0, 0.0, 0.0, 0.0, 0.0],
            },
            HuakMeshClip {
                kind: 1,
                points: [0.0, 1.0, 0.0, 0.0, 0.0, 0.0],
            },
            HuakMeshClip {
                kind: 3,
                points: [0.0; 6],
            },
        ];
        let mut input = HuakMeshPdf {
            vertices: vertices.as_ptr(),
            vertex_count: vertices.len(),
            triangles: triangles.as_ptr(),
            triangle_count: 1,
            clip: clip.as_ptr(),
            clip_count: clip.len(),
            bounds: [0.0, 0.0, 1.0, 1.0],
            evenodd: false,
        };
        let mut output = HuakMeshBuffer {
            data: std::ptr::dangling_mut(),
            len: 1,
            capacity: 1,
        };
        unsafe {
            assert_eq!(huak_mesh_pdf(std::ptr::null(), &mut output), 1);
            assert!(output.data.is_null());
            assert_eq!((output.len, output.capacity), (0, 0));
            clip[0].points[0] = 1e100;
            input.clip = clip.as_ptr();
            assert_eq!(huak_mesh_pdf(&input, &mut output), 1);
            assert!(output.data.is_null());
            clip[0].points[0] = 0.0;
            input.clip = clip.as_ptr();
            assert_eq!(huak_mesh_pdf(&input, &mut output), 0);
            drop(vertices);
            assert!(output.capacity >= output.len);
            assert!(std::slice::from_raw_parts(output.data, output.len).starts_with(b"%PDF-1.4"));
            huak_mesh_pdf_free(output);
        }
    }
}
