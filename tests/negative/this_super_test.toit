// Copyright (C) 2020 Toitware ApS. All rights reserved.

this:
super:

this x:
super x:

class this:
class super:

interface this:
interface super:

this := 499
super := 42

this ::= "foo"
super ::= "bar"

foo1 x/super.A:
  this := "foo"
  super := "bar"
  super
  this

global this super:

class A:
  method this super:
    this
    super

  static statik_method this super:
    this
    super

main: