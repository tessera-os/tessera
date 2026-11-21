#include "CHostDarwin.h"
#include "hosted_excServer.h"
#include <mach/arm/thread_status.h>
#include <mach/mach_time.h>
#include <mach/thread_policy.h>
#include <errno.h>

static _Thread_local th_exception_callback callback;
static _Thread_local void *callback_context;

int th_kevent(int fd, const struct kevent *changes, int nchanges,
    struct kevent *events, int nevents, const struct timespec *timeout) {
  return kevent(fd, changes, nchanges, events, nevents, timeout);
}

kern_return_t hcatch_hosted_exception_raise(mach_port_t port, mach_port_t thread,
    mach_port_t task, int exception, hosted_exception_data_t code,
    mach_msg_type_number_t count) {
  (void)port;
  arm_thread_state64_t state;
  mach_msg_type_number_t words = ARM_THREAD_STATE64_COUNT;
  kern_return_t result = thread_get_state(thread, ARM_THREAD_STATE64,
      (thread_state_t)&state, &words);
  if (result == KERN_SUCCESS && count > 0 && callback) {
    th_exception event = {0};
    thread_identifier_info_data_t identity;
    mach_msg_type_number_t identity_words = THREAD_IDENTIFIER_INFO_COUNT;
    if (thread_info(thread, THREAD_IDENTIFIER_INFO, (thread_info_t)&identity,
        &identity_words) != KERN_SUCCESS) {
      task_terminate(task);
      mach_port_deallocate(mach_task_self(), thread);
      mach_port_deallocate(mach_task_self(), task);
      return KERN_FAILURE;
    }
    event.thread_port = thread;
    event.thread_id = identity.thread_id;
    event.kind = exception;
    event.code = code[0];
    event.subcode = count > 1 ? code[1] : 0;
    event.fault_address = exception == EXC_BAD_ACCESS ? event.subcode : 0;
    event.pc = arm_thread_state64_get_pc(state);
    event.sp = arm_thread_state64_get_sp(state);
    for (int i = 0; i < 29; ++i) event.x[i] = state.__x[i];
    if (callback(callback_context, &event)) {
      arm_thread_state64_set_pc_fptr(state, (void *)event.pc);
      arm_thread_state64_set_sp(state, event.sp);
      for (int i = 0; i < 29; ++i) state.__x[i] = event.x[i];
      result = thread_set_state(thread, ARM_THREAD_STATE64,
          (thread_state_t)&state, ARM_THREAD_STATE64_COUNT);
    } else {
      result = task_terminate(task);
    }
  }
  mach_port_deallocate(mach_task_self(), thread);
  mach_port_deallocate(mach_task_self(), task);
  return result;
}

int th_exception_receive(mach_port_t port, th_exception_callback handler, void *context) {
  union { mach_msg_header_t header; uint8_t bytes[4096]; } request, reply;
  kern_return_t result = mach_msg(&request.header, MACH_RCV_MSG | MACH_RCV_TIMEOUT,
      0, sizeof(request), port, 100, MACH_PORT_NULL);
  if (result == MACH_RCV_TIMED_OUT) return 0;
  if (result != KERN_SUCCESS) return result;
  callback = handler;
  callback_context = context;
  boolean_t handled = hosted_exc_server(&request.header, &reply.header);
  callback = NULL;
  callback_context = NULL;
  if (!handled) {
    mach_msg_destroy(&request.header);
    return KERN_INVALID_ARGUMENT;
  }
  result = mach_msg(&reply.header, MACH_SEND_MSG | MACH_SEND_TIMEOUT,
      reply.header.msgh_size, 0, MACH_PORT_NULL, 100, MACH_PORT_NULL);
  if (result != KERN_SUCCESS) mach_msg_destroy(&reply.header);
  return result;
}

int th_exception_install(mach_port_t target, mach_port_t port, int task) {
  exception_mask_t mask = EXC_MASK_BAD_ACCESS | EXC_MASK_BAD_INSTRUCTION |
      EXC_MASK_ARITHMETIC | EXC_MASK_BREAKPOINT | EXC_MASK_SOFTWARE | EXC_MASK_GUARD;
  exception_behavior_t behavior = EXCEPTION_DEFAULT | MACH_EXCEPTION_CODES;
  return task ? task_set_exception_ports(target, mask, port, behavior, ARM_THREAD_STATE64)
              : thread_set_exception_ports(target, mask, port, behavior, ARM_THREAD_STATE64);
}

int th_initialize_worker(void) {
  return pthread_set_qos_class_self_np(QOS_CLASS_BACKGROUND, 0);
}

void th_release_policy(th_scheduling_state *state) {
  if (state->override) pthread_override_qos_class_end_np(state->override);
  state->override = NULL;
}

int th_apply_policy(pthread_t thread, th_scheduling_state *state, int policy,
    uint64_t period, uint64_t computation) {
  mach_timebase_info_data_t scale;
  mach_timebase_info(&scale);
  __uint128_t p = (__uint128_t)period * scale.denom / scale.numer;
  __uint128_t c = (__uint128_t)computation * scale.denom / scale.numer;
  if (policy == 1 && (!c || c > p || p > UINT32_MAX)) return EINVAL;
  if (state->realtime && policy != 1) {
    int result = thread_policy_set(pthread_mach_thread_np(thread), THREAD_STANDARD_POLICY, NULL, 0);
    if (result != KERN_SUCCESS) return result;
    state->realtime = 0;
  }
  qos_class_t qos = policy == 0 ? QOS_CLASS_USER_INTERACTIVE :
      policy == 3 ? QOS_CLASS_BACKGROUND : QOS_CLASS_DEFAULT;
  pthread_override_t override = NULL;
  if (policy != 3) {
    override = pthread_override_qos_class_start_np(thread, qos, 0);
    if (!override) return errno ? errno : EINVAL;
  }
  th_release_policy(state);
  state->override = override;
  if (policy != 1) return 0;
  thread_time_constraint_policy_data_t constraint = {
      .period = (uint32_t)p, .computation = (uint32_t)c,
      .constraint = (uint32_t)p, .preemptible = TRUE};
  int result = thread_policy_set(pthread_mach_thread_np(thread), THREAD_TIME_CONSTRAINT_POLICY,
      (thread_policy_t)&constraint, THREAD_TIME_CONSTRAINT_POLICY_COUNT);
  if (result == KERN_SUCCESS) state->realtime = 1;
  return result;
}

__attribute__((noinline)) void th_deliberate_fault(void) {
  *(volatile uint64_t *)(uintptr_t)0x1000 = 42;
}
