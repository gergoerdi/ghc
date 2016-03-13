{-# LANGUAGE CPP, CApiFFI #-}

#include "HsFFI.h"
#include "HsBaseConfig.h"

module System.CPUTime.Windows
    ( getCPUTime
    , getCpuTimePrecision
    ) where

import Data.Ratio
import Foreign
import Foreign.C

-- For FILETIME etc. on Windows
#if HAVE_WINDOWS_H
#include <windows.h>
#endif

#ifdef mingw32_HOST_OS
# if defined(i386_HOST_ARCH)
#  define WINDOWS_CCONV stdcall
# elif defined(x86_64_HOST_ARCH)
#  define WINDOWS_CCONV ccall
# else
#  error Unknown mingw32 arch
# endif
#endif

getCPUTime :: IO Integer
getCPUTime = do
     -- NOTE: GetProcessTimes() is only supported on NT-based OSes.
     -- The counts reported by GetProcessTimes() are in 100-ns (10^-7) units.
    allocaBytes (#const sizeof(FILETIME)) $ \ p_creationTime -> do
    allocaBytes (#const sizeof(FILETIME)) $ \ p_exitTime -> do
    allocaBytes (#const sizeof(FILETIME)) $ \ p_kernelTime -> do
    allocaBytes (#const sizeof(FILETIME)) $ \ p_userTime -> do
    pid <- getCurrentProcess
    ok <- getProcessTimes pid p_creationTime p_exitTime p_kernelTime p_userTime
    if toBool ok then do
      ut <- ft2psecs p_userTime
      kt <- ft2psecs p_kernelTime
      return (ut + kt)
     else return 0
  where
        ft2psecs :: Ptr FILETIME -> IO Integer
        ft2psecs ft = do
          high <- (#peek FILETIME,dwHighDateTime) ft :: IO Word32
          low  <- (#peek FILETIME,dwLowDateTime)  ft :: IO Word32
            -- Convert 100-ns units to picosecs (10^-12)
            -- => multiply by 10^5.
          return (((fromIntegral high) * (2^(32::Int)) + (fromIntegral low)) * 100000)

    -- ToDo: pin down elapsed times to just the OS thread(s) that
    -- are evaluating/managing Haskell code.

getCpuTimePrecision :: IO Integer
getCpuTimePrecision =
    return $ round ((1000000000000::Integer) % fromIntegral clockTicks)

type FILETIME = ()
type HANDLE = ()
-- need proper Haskell names (initial lower-case character)
foreign import WINDOWS_CCONV unsafe "GetCurrentProcess" getCurrentProcess :: IO (Ptr HANDLE)
foreign import WINDOWS_CCONV unsafe "GetProcessTimes" getProcessTimes :: Ptr HANDLE -> Ptr FILETIME -> Ptr FILETIME -> Ptr FILETIME -> Ptr FILETIME -> IO CInt
