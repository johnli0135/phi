define i262144 @f7(i32 %x8) {
  %x15 = add i262144 0, 0
  br label %x22
x10:
  %x11 = phi i32 [%x17, %x21], [%x8, %x22]
  %x12 = phi i262144 [%x18, %x21], [0, %x22]
  %x13 = phi i262144 [%x19, %x21], [1, %x22]
  switch i32 %x11, label %x21 [
    i32 0, label %x16
  ]
x16:
  ret i262144 %x12
x21:
  %x17 = sub i32 %x11, 1
  %x18 = add i262144 %x15, %x13
  %x19 = add i262144 %x12, %x13
  br label %x10
x22:
  br label %x10
}
define i32 @main() {
  br label %x24
x24:
  %x25 = call i262144 @f7(i32 250000)
  %x26 = trunc i262144 %x25 to i7
  %x27 = zext i7 %x26 to i32
  ret i32 %x27
}
