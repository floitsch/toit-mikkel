// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import spi
import reader show Reader
import writer show Writer
import gpio


FLASH_5MHZ    ::= 0 ///< The flash runs under 5MHz
FLASH_10MHZ   ::= 1 ///< The flash runs under 10MHz
FLASH_20MHZ   ::= 2 ///< The flash runs under 20MHz
FLASH_26MHZ   ::= 3 ///< The flash runs under 26MHz
FLASH_40MHZ   ::= 4 ///< The flash runs under 40MHz
FLASH_80MHZ   ::= 5 ///< The flash runs under 80MHz

class Flash:
  flash_ := null
  mount_point/string

  /**
  Mounts an sdcard as a FAT file system under $mount_point on the $spi_bus.

  The $cs is the chip select pin for the sdcard holder and $frequency is the spi frequency.

  If $format is true, then format the sdcard with $max_files and $allocation_unit_size if it is not formatted.
  */
  constructor.sdcard
      --.mount_point/string
      --spi_bus/spi.Bus
      --cs/gpio.Pin
      --format/bool=false
      --max_files/int=5
      --allocation_unit_size/int=16384:
    if not mount_point.starts_with "/": throw "INVALID_ARGUMENT"
    flash_ = init_sdcard_ mount_point spi_bus.spi_ cs.num (format?1:0) max_files allocation_unit_size

  /**
  Mounts an external NOR flash chip on the $spi_bus.

  The $cs is the chip select pin for the chip on the spi bus and $frequency is the spi frequency.
    $frequency should be one of the FLASH_FREQ_ constants

  If $format is true, then format the sdcard with $max_files and $allocation_unit_size if it is not formatted.
  */
  constructor.nor
      --.mount_point/string
      --spi_bus/spi.Bus
      --cs/gpio.Pin
      --frequency/int=FLASH_40MHZ
      --format/bool=false
      --max_files/int=5
      --allocation_unit_size/int=16384:
    if not mount_point.starts_with "/": throw "INVALID_ARGUMENT"
    flash_ = init_nor_flash_ mount_point spi_bus.spi_ cs.num frequency (format?1:0) max_files allocation_unit_size

  /**
  Mounts an external NAND flash chip on the $spi_bus.

  The $cs is the chip select pin for the chip on the spi bus and $frequency is the spi frequency.
    $frequency should be one of the FLASH_FREQ_ constants

  If $format is true, then format the sdcard with $max_files and $allocation_unit_size if it is not formatted.
  */
  constructor.nand
      --.mount_point/string
      --spi_bus/spi.Bus
      --cs/gpio.Pin
      --frequency/int=FLASH_40MHZ
      --format/bool=false
      --max_files/int=5
      --allocation_unit_size/int=2048:
    if not mount_point.starts_with "/": throw "INVALID_ARGUMENT"
    freq/int := 0
    mil ::= 1_000_000
    if frequency == FLASH_5MHZ:
      freq = 5_000_000
    else if frequency == FLASH_10MHZ:
      freq = 10_000_000
    else if frequency == FLASH_20MHZ:
      freq = 20_000_000
    else if frequency == FLASH_26MHZ:
      freq = (80_000_000/3).to_int
    else if frequency == FLASH_40MHZ:
      freq = 40_000_000
    else if frequency == FLASH_80MHZ:
      freq = 80_000_000
    else:
      throw "INVALID_ARGUMENT"

    flash_ = init_nand_flash_ mount_point spi_bus.spi_ cs.num freq (format?1:0) max_files allocation_unit_size

  /**
  Unmounts and releases resources for the external storage.
  */
  close:
    close_spi_flash_ flash_

init_nor_flash_ mount_point spi_bus cs frequency format max_files allocation_unit_size -> any:
  #primitive.spi_flash.init_nor_flash

init_nand_flash_ mount_point spi_bus cs frequency format max_files allocation_unit_size -> any:
  #primitive.spi_flash.init_nand_flash

init_sdcard_ mount_point spi_bus cs format max_files allocation_unit_size -> any:
  #primitive.spi_flash.init_sdcard

close_spi_flash_ flash:
  #primitive.spi_flash.close
