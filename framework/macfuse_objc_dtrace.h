/*
 * macfuse_objc_dtrace.h -- the probes of upstream's Framework/macfuse_objc_dtrace.d, compiled out.
 *
 * Upstream's Xcode build runs dtrace -h on macfuse_objc_dtrace.d and its linker turns the probe
 * calls into a __dof_macfuse_o section. The 10.9 build has neither step (the family builds with
 * ld64.lld, and dtrace is not run on a 10.9 build host), so GMUserFileSystem.m's
 * macfuse_objc:::delegate-entry probe is never enabled and costs nothing. The .d file's comment
 * ("Keep the probes defined here in sync with the dummy ones in GMDTrace.h") names this shape.
 */
#ifndef MACFUSE_OBJC_DTRACE_H
#define MACFUSE_OBJC_DTRACE_H

#define MACFUSE_OBJC_DELEGATE_ENTRY(arg0) do { (void)(arg0); } while (0)
#define MACFUSE_OBJC_DELEGATE_ENTRY_ENABLED() (0)
#define MACFUSE_OBJC_DELEGATE_RETURN(arg0) do { (void)(arg0); } while (0)
#define MACFUSE_OBJC_DELEGATE_RETURN_ENABLED() (0)

#endif
