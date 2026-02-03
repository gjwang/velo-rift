//! Recursive Mutex Implementation for macOS/Linux Shim.
//!
//! Pattern 2648/2649 safety: Uses raw pthread primitives to avoid
//! Rust's standard Mutex which is not recursive on all platforms
//! and can deadlock during dyld bootstrap.

use libc::{pthread_mutex_t, pthread_mutexattr_t, PTHREAD_MUTEX_RECURSIVE};
use std::cell::UnsafeCell;
use std::ops::{Deref, DerefMut};

use std::sync::atomic::{AtomicBool, Ordering};

pub struct RecursiveMutex<T> {
    inner: UnsafeCell<pthread_mutex_t>,
    data: UnsafeCell<T>,
    initialized: AtomicBool,
    init_lock: AtomicBool,
}

unsafe impl<T: Send> Send for RecursiveMutex<T> {}
unsafe impl<T: Send> Sync for RecursiveMutex<T> {}

impl<T> RecursiveMutex<T> {
    pub const fn new(data: T) -> Self {
        Self {
            inner: UnsafeCell::new(libc::PTHREAD_MUTEX_INITIALIZER),
            data: UnsafeCell::new(data),
            initialized: AtomicBool::new(false),
            init_lock: AtomicBool::new(false),
        }
    }

    fn ensure_init(&self) {
        if self.initialized.load(Ordering::Acquire) {
            return;
        }

        while self
            .init_lock
            .compare_exchange_weak(false, true, Ordering::Acquire, Ordering::Relaxed)
            .is_err()
        {
            std::hint::spin_loop();
        }

        if !self.initialized.load(Ordering::Relaxed) {
            unsafe {
                let mut attr: pthread_mutexattr_t = std::mem::zeroed();
                libc::pthread_mutexattr_init(&mut attr);
                libc::pthread_mutexattr_settype(&mut attr, PTHREAD_MUTEX_RECURSIVE);
                libc::pthread_mutex_init(self.inner.get(), &attr);
                libc::pthread_mutexattr_destroy(&mut attr);
            }
            self.initialized.store(true, Ordering::Release);
        }

        self.init_lock.store(false, Ordering::Release);
    }

    pub fn lock(&self) -> RecursiveMutexGuard<'_, T> {
        self.ensure_init();
        unsafe {
            libc::pthread_mutex_lock(self.inner.get());
        }
        RecursiveMutexGuard { mutex: self }
    }
}

pub struct RecursiveMutexGuard<'a, T> {
    mutex: &'a RecursiveMutex<T>,
}

impl<T> Deref for RecursiveMutexGuard<'_, T> {
    type Target = T;
    fn deref(&self) -> &Self::Target {
        unsafe { &*self.mutex.data.get() }
    }
}

impl<T> DerefMut for RecursiveMutexGuard<'_, T> {
    fn deref_mut(&mut self) -> &mut Self::Target {
        unsafe { &mut *self.mutex.data.get() }
    }
}

impl<T> Drop for RecursiveMutexGuard<'_, T> {
    fn drop(&mut self) {
        unsafe {
            libc::pthread_mutex_unlock(self.mutex.inner.get());
        }
    }
}
