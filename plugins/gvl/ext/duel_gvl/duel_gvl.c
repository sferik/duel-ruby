/*
 * Duel::GVL::Hook: the total time Ruby threads have spent waiting for
 * the GVL while it's measuring.
 *
 * Ruby calls gvl_event when a thread starts waiting for the GVL (READY,
 * without the GVL) and when it gets it (RESUMED, with it), possibly from
 * several native threads at once, and not necessarily on the native
 * thread that runs the Ruby thread: a thread woken by another (a new
 * one, or one joining a thread that ends) is READY on the waker's, and
 * with M:N threads any may be. So the start of a wait is kept with the
 * Ruby thread, in a slot of the thread-specific storage Ruby keeps for
 * tools like this one (in a native thread's variable, a joining thread's
 * wait would be counted from a READY long before), and each wait is
 * added to one total atomically.
 *
 * The hook is added by start and removed by stop: between them, each
 * time a thread takes the GVL costs two clock readings and Ruby's
 * calling the hook (some 25 ns): 40-70 ns on macOS, more where reading
 * the clock is slow (some virtual machines); outside them, nothing.
 */
#include <ruby.h>
#include <ruby/thread.h>
#include <stdint.h>
#include <time.h>

static rb_internal_thread_specific_key_t ready_key;
static rb_internal_thread_event_hook_t *hook;
static uint64_t waited_ns;
static uint64_t started_at;

/*
 * Monotonic nanoseconds, as cheaply as the platform has them: each
 * handoff of the GVL reads the clock twice (macOS's CLOCK_UPTIME_RAW
 * skips the conversion its CLOCK_MONOTONIC makes, a third of the hook's
 * cost there).
 */
static uint64_t monotonic_ns(void) {
#ifdef __APPLE__
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
#else
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return ((uint64_t)now.tv_sec * 1000000000U) + (uint64_t)now.tv_nsec;
#endif
}

static void gvl_event(rb_event_flag_t event, const rb_internal_thread_event_data_t *data, void *user_data) {
    (void)user_data;
    if (event == RUBY_INTERNAL_THREAD_EVENT_READY) {
        rb_internal_thread_specific_set(data->thread, ready_key, (void *)(uintptr_t)monotonic_ns());
        return;
    }
    uint64_t ready_at = (uint64_t)(uintptr_t)rb_internal_thread_specific_get(data->thread, ready_key);
    /*
     * A thread that was waiting already when measuring started has no
     * start in this stretch: its stamp is older (or from an earlier
     * stretch, its wait's end unseen), and its wait isn't counted.
     */
    if (ready_at >= __atomic_load_n(&started_at, __ATOMIC_RELAXED)) {
        __atomic_fetch_add(&waited_ns, monotonic_ns() - ready_at, __ATOMIC_RELAXED);
    }
    rb_internal_thread_specific_set(data->thread, ready_key, NULL);
}

/* Starts measuring (again); does nothing while measuring. */
static VALUE native_start(VALUE self) {
    (void)self;
    if (hook == NULL) {
        __atomic_store_n(&started_at, monotonic_ns(), __ATOMIC_RELAXED);
        hook = rb_internal_thread_add_event_hook(
            gvl_event, RUBY_INTERNAL_THREAD_EVENT_READY | RUBY_INTERNAL_THREAD_EVENT_RESUMED, NULL);
    }
    return Qnil;
}

/* Stops measuring; the total stays. */
static VALUE native_stop(VALUE self) {
    (void)self;
    if (hook != NULL) {
        rb_internal_thread_remove_event_hook(hook);
        hook = NULL;
    }
    return Qnil;
}

static VALUE native_running_p(VALUE self) {
    (void)self;
    return (hook != NULL) ? Qtrue : Qfalse;
}

/* Nanoseconds all threads have waited for the GVL while measuring. */
static VALUE native_wait_ns(VALUE self) {
    (void)self;
    return ULL2NUM(__atomic_load_n(&waited_ns, __ATOMIC_RELAXED));
}

/* Called by Ruby's `require`, so it must have external linkage. */
void Init_duel_gvl(void) {
    VALUE duel = rb_define_module("Duel");
    VALUE gvl = rb_define_module_under(duel, "GVL");
    VALUE hook_module = rb_define_module_under(gvl, "Hook");

    ready_key = rb_internal_thread_specific_key_create();
    rb_define_module_function(hook_module, "start", native_start, 0);
    rb_define_module_function(hook_module, "stop", native_stop, 0);
    rb_define_module_function(hook_module, "running?", native_running_p, 0);
    rb_define_module_function(hook_module, "wait_ns", native_wait_ns, 0);
}
