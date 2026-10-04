#![allow(dead_code)]
#[derive(Copy, Clone)]
#[repr(i16)]
enum Mode { Idle = -2, Busy = 7 }
#[repr(u64)]
enum Big { High = 0x8000000000000001 }
#[derive(Copy, Clone)]
struct Pair { left: i32, right: u64 }
#[unsafe(no_mangle)]
#[inline(never)]
pub extern "C" fn value_checkpoint() { std::hint::black_box(()); }
fn main() {
    let numbers = [11i32, -22, 33, 44];
    let slice: &[i32] = &numbers[1..];
    let text = "hello λ\nworld";
    let empty: &[i32] = &[];
    let mode = Mode::Idle;
    let high = Big::High;
    let pair = Pair { left: -17, right: 9001 };
    let variant: Option<Pair> = Some(pair);
    let bytes: &[u8] = &[0, 255, 65];
    value_checkpoint();
    std::hint::black_box((&numbers, &slice, &text, &empty, &mode, &high, &pair, &variant, &bytes));
}
