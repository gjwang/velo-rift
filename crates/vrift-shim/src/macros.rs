#[macro_export]
macro_rules! shim_log {
    ($msg:expr) => {
        $crate::LOGGER.log($msg)
    };
}

#[macro_export]
macro_rules! vfs_log {
    ($($arg:tt)*) => {
        {
            let pid = unsafe { libc::getpid() };
            let msg = format!("[VFS][{}] {}\n", pid, format_args!($($arg)*));
            unsafe {
                $crate::LOGGER.log(&msg);
                if $crate::state::DEBUG_ENABLED.load(std::sync::atomic::Ordering::Relaxed) {
                    libc::write(2, msg.as_ptr() as *const libc::c_void, msg.len());
                }
            }
        }
    };
}

#[macro_export]
macro_rules! get_real {
    ($storage:ident, $name:literal, $t:ty) => {{
        let p = $storage.load(std::sync::atomic::Ordering::Acquire);
        if !p.is_null() {
            std::mem::transmute::<*mut libc::c_void, $t>(p)
        } else {
            // zero-alloc C string constant
            let f = libc::dlsym(
                libc::RTLD_NEXT,
                concat!($name, "\0").as_ptr() as *const libc::c_char,
            );
            $storage.store(f, std::sync::atomic::Ordering::Release);
            std::mem::transmute::<*mut libc::c_void, $t>(f)
        }
    }};
}

#[macro_export]
macro_rules! get_real_shim {
    ($storage:ident, $name:literal, $it:ident, $t:ty) => {{
        #[cfg(target_os = "macos")]
        {
            std::mem::transmute::<*const (), $t>($it.old_func)
        }
        #[cfg(target_os = "linux")]
        {
            get_real!($storage, $name, $t)
        }
    }};
}
