import strutils
import strformat
import sets
import os
import nre
import tables
#import ospaths
import selectors
import sequtils
from posix import nil
import options


const SYSPATH = "/sys/bus/usb/devices"

proc stripReadFile(path: string):string =
  ## Read data from 'path' and return it as a string. Return the empty string
  ## if the file does not exist, cannot be read, or has an error.
  try:
    return readFile(path).strip()
  except:
    return ""

proc findDevicePath(dirname:string): string =
  ## Scan a directory hierarchy and find interface
  ## number 1 then searchfor a name that contains "hidraw".
  ## Return this name.
  let thisDir = splitPath(dirname).tail
  for dirpath in walkDir(dirname, true):
    if dirpath.kind == pcDir and dirpath.path.find(re("^"&thisDir)).isSome():
      let fullPath = joinPath(dirname, dirpath.path)
      let interfaceNumPath = joinPath(fullPath, "bInterfaceNumber")
      if parseHexInt(stripReadFile(interfaceNumPath)) == 1:
        #interface number 1 is the one we want.
        for filepath in walkDirRec(fullpath, {pcFile, pcLinkToFile, pcDir, pcLinktoDir}, {pcDir}):
          var matches = filepath.find(re"(hidraw[0-9])$")
          if matches.isSome():
            return joinPath("/dev", matches.get.captures[0])

type 
  TemperUsbDevice* = ref object of RootObj
    vendorId: uint16
    productId: uint16
    manufacturer: string
    product: string
    busnum: uint
    devnum: uint
    devicePath: string
    isValid: bool
    isVerbose: bool
  TemperDeviceReading* = object of RootObj
    externalTemp: float
    units: string
    isValid:bool
    firmware: string

proc getUsbDevice(dirname:string): TemperUsbDevice = 
  ## Examine the files in 'dirname', looking for files with well-known
  ## names expected to be in the /sys hierarchy under Linux for USB devices.
  ## Return a dictionary of the information gathered. If no information is found
  ## (i.e., because the directory is not for a USB device) return None.
  result = TemperUsbDevice(isValid:false, isVerbose: false)
  let vendorId = stripReadFile(joinPath(dirname, "idVendor"))
  if vendorId == "":
    return result
  result.vendorId = uint16(parseHexInt(vendorId))
  let productId = stripReadFile(joinPath(dirname, "idProduct"))
  result.productId = uint16(parseHexInt(productId))
  result.manufacturer = stripReadFile(joinPath(dirname, "manufacturer"))
  result.product = stripReadFile(joinPath(dirname, "product"))
  result.busnum = parseUInt(stripReadFile(joinPath(dirname, "busnum")))
  result.devnum = parseUInt(stripReadFile(joinPath(dirname, "devnum")))
  result.devicePath = findDevicePath(dirname)
  result.isValid = true

proc isValidVidPid(dev: TemperUsbDevice): bool =
  if dev.vendorId == 0x413d and dev.productId == 0x2107:
    return true
  return false

proc getTemperUsbDevices*(): seq[TemperUsbDevice] =
  ## Scan a well-known Linux hierarchy in /sys and try to find all of the
  ## USB devices on a system. Return these as a seqence.
  result = newSeq[TemperUsbDevice]()
  for filetype, filepath in walkDir(SYSPATH):
    if filetype == pcDir or fileType == pcLinkToDir:
      let dev = getUsbDevice(filepath)
      if dev.isValid and dev.isValidVidPid():
        result.add(dev)

proc charSeqToString(str: seq[uint8]): string =
  result = newStringOfCap(len(str))
  for ch in str:
    add(result, chr(ch))

proc deviceTransaction(dev:TemperUsbDevice, writepack:openArray[uint8]):seq[uint8] =
  let devfd = posix.open(dev.devicePath, posix.O_RDWR)
  if devfd < 0:
    echo("Error opening ", dev.devicePath)
    return result
  # Close the file object when we are done with it
  defer: discard posix.close(devfd)

  let written = posix.write(devfd, cast [ptr uint8](unsafeAddr(writepack)), writepack.len)
  if written != writepack.len:
    echo("Error writing to ", dev.devicePath)
    return result

  result = newSeq[uint8]()
  var rawBuffer : array[8, uint8]
  while true:
    var selector = newSelector[int]()
    selector.registerHandle(cast[int](devfd), {Read}, 0)
    var ready = selector.select(100)
    if ready.len == 0 or ready[0].fd != devfd:
      break;
    let numread = posix.read(devfd, cast [ptr uint8](unsafeAddr(rawBuffer)), rawBuffer.len)
    for i in 0 ..< numread:
      result.add(rawBuffer[i])

proc readDevice*(dev: TemperUsbDevice): TemperDeviceReading =
  ## Read the firmware version, temperature, and humidity from the device and
  ## return a TemperDeviceReading containing these data.

  # Using the Linux hidraw device, send the special commands and receive the
  # raw data. Then call '_parse_bytes' based on the firmware version to provide
  # temperature and humidity information.
  # 
  # A TemperDeviceReading object is returned.
  result.isValid = false
  
  let firmwareVersionPack = [0x01'u8, 0x86'u8, 0xff'u8, 0x01'u8, 0'u8, 0'u8, 0'u8, 0'u8]
  let fwBytes = deviceTransaction(dev, firmwareVersionPack)
  if fwBytes.len < 8:
    return result
  let fwVer = charSeqToString(fwBytes)

  let readingPack = [0x01'u8, 0x80'u8, 0x33'u8, 0x01'u8, 0'u8, 0'u8, 0'u8, 0'u8]
  let readingBytes = deviceTransaction(dev, readingPack)
  if readingBytes.len < 8:
    return result

  var reading:float = (float(readingBytes[2]) * 256 + float(readingBytes[3])) / 100

  result = TemperDeviceReading(
    externalTemp: reading,
    units: "C",
    isValid:true,
    firmware:fwVer)

# test run
if isMainModule:
  for x in getTemperUsbDevices().items():
    let reading = x.readDevice()
    echo fmt"{reading.firmware} {reading.externalTemp:3.1f}{reading.units}"

  

