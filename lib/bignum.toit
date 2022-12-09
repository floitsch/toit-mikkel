// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import encoding.hex
import binary show BIG_ENDIAN

BIGNUM_ADD_ ::= 0
BIGNUM_SUB_ ::= 1
BIGNUM_MUL_ ::= 2
BIGNUM_DIV_ ::= 3
BIGNUM_MOD_ ::= 4

class Bignum:
  negative_/bool := ?
  limbs_/ByteArray := ?

  constructor.with_bytes .negative_/bool .limbs_/ByteArray:

  constructor data/string:
    if data[0] == '-':
      negative_ = true
      data = data[1..]
    else:
      negative_ = false
    limbs_ = hex.decode data

  static int_to_array_ i/int -> ByteArray:
    result := ByteArray 8
    BIG_ENDIAN.put_int64 result 0 i
    return result

  trans_other_ other/any -> Bignum:
    if other is int:
      other = Bignum.with_bytes
          other < 0
          int_to_array_ other.abs
    else if other is not Bignum:
      throw "WRONG_OBJECT_TYPE"
    return other

  basic_operator_ operation/int other/any:
    other = trans_other_ other
    result :=  bignum_operator_ operation negative_ limbs_ other.negative_ other.limbs_
    return Bignum.with_bytes result[0] result[1]

  operator + other -> Bignum:
    return basic_operator_ BIGNUM_ADD_ other

  operator - other -> Bignum:
    return basic_operator_ BIGNUM_SUB_ other

  operator * other -> Bignum:
    return basic_operator_ BIGNUM_MUL_ other

  operator / other -> Bignum:
    return basic_operator_ BIGNUM_DIV_ other

  operator % other -> Bignum:
    return basic_operator_ BIGNUM_MOD_ other
  
  operator == other -> bool:
    other = trans_other_ other
    
    if negative_ != other.negative_:
      return false

    return limbs_ == other.limbs_
  
  stringify -> string:
    s := negative_ ? "-0x" : "0x" 
    s += hex.encode limbs_
    return s

mod_exp A/Bignum B/Bignum C/Bignum -> Bignum:
  result := bignum_exp_mod_ A.negative_ A.limbs_ B.negative_ B.limbs_ C.negative_ C.limbs_
  return Bignum.with_bytes result[0] result[1]

bignum_operator_ operator_id a_sign a_limbs b_sign b_limbs:
  #primitive.bignum.binary_operator

bignum_exp_mod_ a_sign a_limbs b_sign b_limbs c_sign c_limbs:
  #primitive.bignum.exp_mod