/* Deterministic CFI for saved-byte tests, never executed. */
.text
.globl saved_leaf
.type saved_leaf,@function
saved_leaf:
.cfi_startproc
.cfi_def_cfa %rsp,8
.cfi_offset %rip,-8
nop
ret
.cfi_endproc
.size saved_leaf,.-saved_leaf
.globl saved_parent
.type saved_parent,@function
saved_parent:
.cfi_startproc
.cfi_def_cfa %rsp,8
.cfi_offset %rip,-8
nop
ret
.cfi_endproc
.size saved_parent,.-saved_parent
.globl saved_signal
.type saved_signal,@function
saved_signal:
.cfi_startproc
.cfi_signal_frame
nop
ret
.cfi_endproc
.size saved_signal,.-saved_signal
.globl saved_cycle
.type saved_cycle,@function
saved_cycle:
.cfi_startproc
.cfi_def_cfa %rsp,0
.cfi_same_value %rip
nop
ret
.cfi_endproc
.size saved_cycle,.-saved_cycle
.globl saved_nocfi
.type saved_nocfi,@function
saved_nocfi:
nop
ret
.size saved_nocfi,.-saved_nocfi
.section .note.GNU-stack,"",@progbits
