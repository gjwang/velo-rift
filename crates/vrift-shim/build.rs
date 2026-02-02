//! Build script for vrift-shim
//!
//! Compiles C variadic wrappers that correctly handle va_list on macOS ARM64.
//! C compiler generates proper ABI code for variadic functions.

fn main() {
    // Only compile C shim on macOS
    #[cfg(target_os = "macos")]
    {
        println!("cargo:rerun-if-changed=src/c/variadic_shim.c");

        cc::Build::new()
            .file("src/c/variadic_shim.c")
            .opt_level(2)
            .compile("variadic_shim");
    }
}
