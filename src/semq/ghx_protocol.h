#ifndef XODB_GHX_PROTOCOL_H
#define XODB_GHX_PROTOCOL_H

/* The supervisor must receive this exact reply before it sends an image path
 * or any other analysis state to a newly started native worker.  Bump the
 * protocol or producer when an incompatible request contract changes. */
#define GHX_WORKER_PROTOCOL "1"
#define GHX_WORKER_VERSION "0.4.2"
#define GHX_WORKER_PRODUCER "ghx_worker/" GHX_WORKER_VERSION
#define GHX_WORKER_SCHEMA "xodb.ghidra.function_graph/0.4.1"
#define GHX_WORKER_CAPABILITIES "decompile,function_map,immutable_snapshot,strict_bounds"
#define GHX_WORKER_HELLO_LINE \
	"HELLO\tprotocol=" GHX_WORKER_PROTOCOL \
	"\tproducer=" GHX_WORKER_PRODUCER \
	"\tschema=" GHX_WORKER_SCHEMA \
	"\tcapabilities=" GHX_WORKER_CAPABILITIES

#define GHX_SUPERVISOR_PROTOCOL "1"
#define GHX_SUPERVISOR_PRODUCER "ghx_supervise/0.4.2"
#define GHX_SUPERVISOR_CAPABILITIES "decompile,cancel,deadline,process_group_reap,noreplace_publish"
#define GHX_SUPERVISOR_HELLO_LINE \
	"HELLO\tprotocol=" GHX_SUPERVISOR_PROTOCOL \
	"\tproducer=" GHX_SUPERVISOR_PRODUCER \
	"\tschema=" GHX_WORKER_SCHEMA \
	"\tcapabilities=" GHX_SUPERVISOR_CAPABILITIES

#endif
