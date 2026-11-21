#ifndef C_HOST_DARWIN_H
#define C_HOST_DARWIN_H
#include <stdint.h>
#include <mach/mach.h>
#include <pthread.h>
#include <pthread/qos.h>
#include <sys/event.h>

typedef struct {
  int32_t kind;
  uint64_t code, subcode, fault_address, pc, sp, x[29];
} th_exception;
typedef int (*th_exception_callback)(void *, th_exception *);
typedef int64_t *hosted_exception_data_t;
int th_exception_receive(mach_port_t, th_exception_callback, void *);
int th_exception_install(mach_port_t, mach_port_t, int);
typedef struct { pthread_override_t override; int realtime; } th_scheduling_state;
int th_initialize_worker(void);
int th_apply_policy(pthread_t, th_scheduling_state *, int, uint64_t, uint64_t);
void th_release_policy(th_scheduling_state *);
void th_deliberate_fault(void);
int th_kevent(int, const struct kevent *, int, struct kevent *, int, const struct timespec *);
#endif
