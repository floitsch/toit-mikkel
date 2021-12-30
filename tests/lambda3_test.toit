// Copyright (C) 2019 Toitware ApS. All rights reserved.

import expect show *

class A:
  fun := null

  constructor:
  constructor .fun:

  foo: return fun.call
  bar: return 499

  test:
    x := 0
    result := :: x
    x++
    return result

was_executed := false
class B:
  foo:
    a := null
    a = A::
      expect_equals 499 a.bar
      was_executed = true
    return a

main:
  f := (A).test
  expect_equals 1 f.call

  a := (B).foo
  a.foo
  expect was_executed