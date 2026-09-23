pub mod api;
mod frb_generated;

/// `MainActivity.initNdkContext(context)`: keeps the application context for the Rust side,
/// which reaches the Android Keystore through it (passwords are stored there).
#[cfg(target_os = "android")]
#[no_mangle]
pub extern "system" fn Java_dev_zonda_mail_1app_MainActivity_initNdkContext(
    env: jni::JNIEnv,
    _activity: jni::objects::JObject,
    context: jni::objects::JObject,
) {
    use std::sync::OnceLock;
    // Held for the life of the process: ndk-context keeps a raw pointer to it.
    static CONTEXT: OnceLock<Option<jni::objects::GlobalRef>> = OnceLock::new();
    CONTEXT.get_or_init(|| {
        let global = env.new_global_ref(&context).ok()?;
        let vm = env.get_java_vm().ok()?;
        // SAFETY: a live JavaVM and a global reference that is never dropped.
        unsafe {
            ndk_context::initialize_android_context(
                vm.get_java_vm_pointer().cast(),
                global.as_obj().as_raw().cast(),
            );
        }
        Some(global)
    });
}
