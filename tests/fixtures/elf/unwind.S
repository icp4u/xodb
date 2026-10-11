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
.globl saved_bad_return
.type saved_bad_return,@function
saved_bad_return:
.cfi_startproc
.cfi_def_cfa %rsp,8
/* DW_CFA_expression rip: drop the seeded CFA, leaving no return address. */
.cfi_escape 0x10,16,1,0x13
nop
ret
.cfi_endproc
.size saved_bad_return,.-saved_bad_return
.globl saved_outermost
.type saved_outermost,@function
saved_outermost:
.cfi_startproc
.cfi_def_cfa %rsp,8
.cfi_undefined %rip
nop
ret
.cfi_endproc
.size saved_outermost,.-saved_outermost
.section .note.GNU-stack,"",@progbits
