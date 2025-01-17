# Copyright (C) 2021 Toitware ApS.
#
# This library is free software; you can redistribute it and/or
# modify it under the terms of the GNU Lesser General Public
# License as published by the Free Software Foundation; version
# 2.1 only.
#
# This library is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# Lesser General Public License for more details.
#
# The license can be found in the file `LICENSE` in the top level
# directory of this repository.

set(TOIT_FAILING_TESTS
)

if ("${CMAKE_SYSTEM_NAME}" STREQUAL "Windows" OR "${CMAKE_SYSTEM_NAME}" STREQUAL "MSYS")
  # The following tests seem to be broken because of 'realpath' in the current
  # host package not working correctly.
  list(APPEND TOIT_FAILING_TESTS
    tests/optimizations/eager-global-test.toit
    tests/optimizations/fold-test.toit
    tests/optimizations/lambda-test.toit
    tests/optimizations/uninstantiated-classes-test.toit
  )
endif()
