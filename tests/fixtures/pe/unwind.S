/* Real COFF/SEH tables assembled by Clang and linked by LLD. Exported
 * instruction boundaries let the host oracle use exact compiler addresses. */
.text
.globl uw_push
.seh_proc uw_push
uw_push:
 pushq %rbx
.seh_pushreg %rbx
.globl uw_push_pushed
uw_push_pushed:
 subq $32,%rsp
.seh_stackalloc 32
.seh_endprologue
.globl uw_push_body
uw_push_body:
 nop
.globl uw_push_epilog
uw_push_epilog:
 addq $32,%rsp
.globl uw_push_pop
uw_push_pop:
 popq %rbx
.globl uw_push_ret
uw_push_ret:
 ret
.seh_endproc

.globl uw_frame
.seh_proc uw_frame
uw_frame:
 pushq %rbp
.seh_pushreg %rbp
.globl uw_frame_pushed
uw_frame_pushed:
 subq $64,%rsp
.seh_stackalloc 64
.globl uw_frame_allocated
uw_frame_allocated:
 leaq 32(%rsp),%rbp
.seh_setframe %rbp,32
.seh_endprologue
.globl uw_frame_body
uw_frame_body:
 nop
.globl uw_frame_epilog
uw_frame_epilog:
 leaq 32(%rbp),%rsp
.globl uw_frame_pop
uw_frame_pop:
 popq %rbp
.globl uw_frame_ret
uw_frame_ret:
 ret
.seh_endproc

.globl uw_saved
.seh_proc uw_saved
uw_saved:
 subq $88,%rsp
.seh_stackalloc 88
.globl uw_saved_allocated
uw_saved_allocated:
 movq %r12,32(%rsp)
.seh_savereg %r12,32
.globl uw_saved_gpr
uw_saved_gpr:
 movaps %xmm6,48(%rsp)
.seh_savexmm %xmm6,48
.seh_endprologue
.globl uw_saved_body
uw_saved_body:
 nop
 movaps 48(%rsp),%xmm6
 movq 32(%rsp),%r12
.globl uw_saved_epilog
uw_saved_epilog:
 addq $88,%rsp
.globl uw_saved_ret
uw_saved_ret:
 ret
.seh_endproc

.globl uw_large
.seh_proc uw_large
uw_large:
 subq $4096,%rsp
.seh_stackalloc 4096
.seh_endprologue
.globl uw_large_body
uw_large_body:
 nop
.globl uw_large_epilog
uw_large_epilog:
 addq $4096,%rsp
.globl uw_large_ret
uw_large_ret:
 ret
.seh_endproc

.globl uw_far
.seh_proc uw_far
uw_far:
 subq $524296,%rsp
.seh_stackalloc 524296
.seh_endprologue
.globl uw_far_body
uw_far_body:
 nop
.globl uw_far_epilog
uw_far_epilog:
 addq $524296,%rsp
.globl uw_far_ret
uw_far_ret:
 ret
.seh_endproc

.globl uw_leaf
uw_leaf:
 ret

.section .drectve,"yn"
.ascii " -export:uw_push -export:uw_push_pushed -export:uw_push_body -export:uw_push_epilog -export:uw_push_pop -export:uw_push_ret"
.ascii " -export:uw_frame -export:uw_frame_pushed -export:uw_frame_allocated -export:uw_frame_body -export:uw_frame_epilog -export:uw_frame_pop -export:uw_frame_ret"
.ascii " -export:uw_saved -export:uw_saved_allocated -export:uw_saved_gpr -export:uw_saved_body -export:uw_saved_epilog -export:uw_saved_ret"
.ascii " -export:uw_large -export:uw_large_body -export:uw_large_epilog -export:uw_large_ret"
.ascii " -export:uw_far -export:uw_far_body -export:uw_far_epilog -export:uw_far_ret -export:uw_leaf"
