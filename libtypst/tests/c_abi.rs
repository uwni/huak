//! Compile independent C and C++ consumers, then load Cargo's current DSO.
use std::{path::Path, path::PathBuf, process::Command};

fn checked(command: &mut Command, description: &str) -> std::process::Output {
    let output = command.output().unwrap_or_else(|error| {
        panic!("{description} could not start: {error}");
    });
    assert!(
        output.status.success(),
        "{description} failed:\n{}\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    output
}

fn current_library() -> PathBuf {
    let filename = if cfg!(target_os = "macos") {
        "libtypst.dylib"
    } else if cfg!(target_os = "windows") {
        "typst.dll"
    } else {
        "libtypst.so"
    };
    let executable = std::env::current_exe().expect("locate the current test executable");
    let library = executable
        .parent()
        .expect("test executable must be in Cargo's dependency directory")
        .join(filename);
    // The profile-directory artifact can belong to an earlier cargo build.
    // Only this cargo test invocation's dependency artifact is acceptable.
    assert!(
        library.is_file(),
        "missing current DSO: {}",
        library.display()
    );
    library
}

fn check_svg(path: &Path) {
    let svg = std::fs::read_to_string(path).expect("C host must export SVG");
    assert!(svg.contains("<svg"), "missing SVG root: {}", path.display());
    assert!(svg.trim_end().ends_with("</svg>"));
    assert!(svg.contains("<path"), "missing native vector geometry");
}

fn check_selectable_pdf(path: &Path) {
    let pdf = std::fs::read(path).expect("C host must export PDF");
    assert!(pdf.starts_with(b"%PDF-"));
    for marker in [b"/FontFile".as_slice(), b"/ToUnicode".as_slice()] {
        assert!(pdf.windows(marker.len()).any(|part| part == marker));
    }
    let output = checked(
        Command::new("pdftotext").arg(path).arg("-"),
        "extract actual PDF text with pdftotext",
    );
    let text = String::from_utf8_lossy(&output.stdout);
    assert!(
        text.contains("Selectable Alpha"),
        "PDF must preserve copyable text; extracted {text:?}"
    );
}

fn check_pdf_creator(path: &Path, expected: &str) {
    let info = checked(
        Command::new("pdfinfo").arg(path),
        "read PDF information dictionary",
    );
    let info = String::from_utf8(info.stdout).expect("pdfinfo emits UTF-8");
    let creator = info.lines().find_map(|line| line.strip_prefix("Creator:"));
    assert_eq!(creator.map(str::trim), Some(expected));
    let metadata = checked(
        Command::new("pdfinfo").arg("-meta").arg(path),
        "read PDF XMP metadata",
    );
    let metadata = String::from_utf8(metadata.stdout).expect("XMP emits UTF-8");
    let escaped = expected
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;");
    assert!(metadata.contains(&format!("<xmp:CreatorTool>{escaped}</xmp:CreatorTool>")));
}

#[test]
fn independent_c_host_exercises_stable_abi() {
    let package = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let directory = package.join("target/acceptance");
    std::fs::create_dir_all(&directory).expect("create acceptance artifact directory");
    for name in [
        "acceptance.svg",
        "acceptance.pdf",
        "native-scene.svg",
        "native-scene.pdf",
        "outlined.svg",
        "creator-document.pdf",
        "creator-layout.pdf",
        "creator-scene.pdf",
        "legacy-pdf-options.pdf",
    ] {
        match std::fs::remove_file(directory.join(name)) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => panic!("remove prior acceptance artifact {name}: {error}"),
        }
    }
    let font = typst_assets::fonts()
        .next()
        .expect("the acceptance fixture requires a bundled font");
    std::fs::write(directory.join("font.ttf"), font)
        .expect("write the caller-provided font fixture");
    let executable = directory.join(if cfg!(windows) {
        "c-abi-host.exe"
    } else {
        "c-abi-host"
    });

    let mut compiler = Command::new(std::env::var_os("CC").unwrap_or_else(|| "cc".into()));
    compiler
        .current_dir(&package)
        .args(["-std=c11", "-Wall", "-Wextra", "-Werror", "-pedantic"])
        .arg("-I")
        .arg(package.join("include"))
        .arg(package.join("tests/fixtures/acceptance.c"))
        .arg("-o")
        .arg(&executable);
    if cfg!(target_os = "linux") {
        compiler.arg("-ldl");
    }
    checked(&mut compiler, "compile the independent C11 consumer");

    let cpp = directory.join("header.cpp");
    std::fs::write(&cpp, "#include \"libtypst.h\"\nint main() { return 0; }\n")
        .expect("write independent C++ header probe");
    checked(
        Command::new(std::env::var_os("CXX").unwrap_or_else(|| "c++".into()))
            .args([
                "-std=c++17",
                "-Wall",
                "-Wextra",
                "-Werror",
                "-pedantic",
                "-fsyntax-only",
            ])
            .arg("-I")
            .arg(package.join("include"))
            .arg(&cpp),
        "compile the generated header as strict C++17",
    );

    checked(
        Command::new(&executable)
            .arg(current_library())
            .arg(&directory),
        "run the independent C host against the current DSO",
    );
    check_svg(&directory.join("acceptance.svg"));
    check_svg(&directory.join("native-scene.svg"));
    check_svg(&directory.join("outlined.svg"));
    check_selectable_pdf(&directory.join("acceptance.pdf"));
    check_selectable_pdf(&directory.join("native-scene.pdf"));
    let default_creator = format!("Typst {}", typst_core::utils::version().raw());
    for name in [
        "acceptance.pdf",
        "native-scene.pdf",
        "legacy-pdf-options.pdf",
    ] {
        check_pdf_creator(&directory.join(name), &default_creator);
    }
    for name in [
        "creator-document.pdf",
        "creator-layout.pdf",
        "creator-scene.pdf",
    ] {
        check_pdf_creator(&directory.join(name), "C host café <&> (test)");
    }
}
