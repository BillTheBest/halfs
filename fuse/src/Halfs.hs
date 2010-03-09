-- | Command line tool for mounting a halfs filesystem from userspace via
-- hFUSE/FUSE.

{-# OPTIONS_GHC -fno-warn-orphans #-}

module Main
where

import Control.Applicative
import Control.Exception     (assert)
import Data.Array.IO         (IOUArray)
import Data.IORef            (IORef)
import Data.Word             
import Prelude hiding (log)  
import System.Console.GetOpt 
import System.Directory      (doesFileExist, getCurrentDirectory)
import System.Environment
import System.IO
import System.Posix.Types    ( ByteCount
                             , DeviceID
                             , EpochTime
                             , FileMode
                             , FileOffset
                             , GroupID
                             , UserID
                             )

import System.Fuse     

import Halfs.Classes
import Halfs.CoreAPI
import Halfs.File (FileHandle)
import Halfs.HalfsState
import Halfs.Monad
import System.Device.BlockDevice
import System.Device.File
import System.Device.Memory
import Tests.Utils

import qualified Data.ByteString as BS
import qualified Halfs.Types     as H

-- Halfs-specific stuff we carry around in our FUSE functions; note that the
-- FUSE library does this via opaque ptr to user data, but since hFUSE
-- reimplements fuse_main and doesn't seem to provide a way to hang onto private
-- data, we just carry the data ourselves.
type Logger m              = String -> m ()
type HalfsSpecific b r l m = (Logger m, HalfsState b r l m)

-- This isn't a halfs limit, but we have to pick something for FUSE.
maxNameLength :: Integer
maxNameLength = 32768

main :: IO ()
main = do
  (opts, argv1) <- do
    argv0 <- getArgs
    case getOpt RequireOrder options argv0 of
      (o, n, [])   -> return (foldl (flip ($)) defOpts o, n)
      (_, _, errs) -> ioError $ userError $ concat errs ++ usageInfo hdr options
        where hdr = "Usage: halfs [OPTION...] <FUSE CMDLINE>"

  let sz = optSecSize opts; n = optNumSecs opts
  (exists, dev) <- maybe (fail "Unable to create device") return
    =<<
    let wb = (liftM . liftM) . (,) in
    if optMemDev opts
     then wb False $ newMemoryBlockDevice n sz <* putStrLn "Created new memdev."
     else case optFileDev opts of
            Nothing -> fail "Can't happen"
            Just fp -> do
              exists <- doesFileExist fp
              wb exists $ 
                if exists
                 then newFileBlockDevice fp sz 
                        <* putStrLn "Created filedev from existing file."
                 else withFileStore False fp sz n (`newFileBlockDevice` sz)
                        <* putStrLn "Created filedev from new file."  

  when (not exists) $ exec $ newfs dev >> return ()
  fs <- exec $ mount dev

  log <- liftM (logger . snd) $
           (`openTempFile` "halfs.log") =<< getCurrentDirectory

  withArgs argv1 $ fuseMain (ops (log, fs)) defaultExceptionHandler
  -- TODO: If a new file was created and fuseMain fails to mount (e.g.,
  -- because the mount point was not given or invalid, etc.), delete the
  -- file or CoreAPI.unmount it.

--------------------------------------------------------------------------------
-- Halfs-hFUSE filesystem operation implementation

-- JS: ST monad impls will have to get mapped to hFUSE ops via stToIO?
ops :: HalfsSpecific (IOUArray Word64 Bool) IORef IOLock IO
    -> FuseOperations FileHandle
ops hsp = FuseOperations
  { fuseGetFileStat          = \fp -> do ctx <- getFuseContext
                                         halfsGetFileStat hsp ctx fp
  , fuseReadSymbolicLink     = halfsReadSymbolicLink     hsp
  , fuseCreateDevice         = halfsCreateDevice         hsp
  , fuseCreateDirectory      = halfsCreateDirectory      hsp
  , fuseRemoveLink           = halfsRemoveLink           hsp
  , fuseRemoveDirectory      = halfsRemoveDirectory      hsp
  , fuseCreateSymbolicLink   = halfsCreateSymbolicLink   hsp
  , fuseRename               = halfsRename               hsp
  , fuseCreateLink           = halfsCreateLink           hsp
  , fuseSetFileMode          = halfsSetFileMode          hsp
  , fuseSetOwnerAndGroup     = halfsSetOwnerAndGroup     hsp
  , fuseSetFileSize          = halfsSetFileSize          hsp
  , fuseSetFileTimes         = halfsSetFileTimes         hsp
  , fuseOpen                 = halfsOpen                 hsp
  , fuseRead                 = halfsRead                 hsp
  , fuseWrite                = halfsWrite                hsp
  , fuseGetFileSystemStats   = halfsGetFileSystemStats   hsp
  , fuseFlush                = halfsFlush                hsp
  , fuseRelease              = halfsRelease              hsp
  , fuseSynchronizeFile      = halfsSynchronizeFile      hsp
  , fuseOpenDirectory        = halfsOpenDirectory        hsp
  , fuseReadDirectory        = halfsReadDirectory        hsp
  , fuseReleaseDirectory     = halfsReleaseDirectory     hsp
  , fuseSynchronizeDirectory = halfsSynchronizeDirectory hsp
  , fuseAccess               = halfsAccess               hsp
  , fuseInit                 = halfsInit                 hsp
  , fuseDestroy              = halfsDestroy              hsp
  }

halfsGetFileStat :: HalfsCapable b t r l m =>
                    HalfsSpecific b r l m
                 -> FuseContext
                 -> FilePath
                 -> m (Either Errno FileStat)
halfsGetFileStat (log, fs) _ctx fp = do
  log $ "halfsGetFileStat: fp = " ++ show fp
  x <- execOrErrno eINVAL id $ fstat fs fp
  log $ "halfsGetFileStat: fstat = " ++ show x  
  return (f2f `fmap` x)
  where
    -- TODO: Check how these asserts are handled by the fuse EH.
    chkb16 x = assert (x' <= fromIntegral (maxBound :: Word16)) x'
               where x' = fromIntegral x
    chkb32 x = assert (x' <= fromIntegral (maxBound :: Word32)) x'
               where x' = fromIntegral x
    -- 
    f2f stat =
      let entryType = case H.fsType stat of
                        H.RegularFile -> RegularFile
                        H.Directory   -> Directory
                        H.Symlink     -> SymbolicLink
                        -- TODO: Represent remaining FUSE entry types
                        H.AnyFileType -> error "Invalid fstat type"
      in FileStat
      { statEntryType        = entryType
      , statFileMode         = entryTypeToFileMode entryType
      , statLinkCount        = chkb16 $ H.fsNumLinks stat
      , statFileOwner        = chkb32 $ H.fsUID stat
      , statFileGroup        = chkb32 $ H.fsGID stat
      , statSpecialDeviceID  = 0 -- XXX/TODO: Do we need to distinguish by
                                 -- blkdev, or is this for something else?
      , statFileSize         = fromIntegral $ H.fsSize stat
      , statBlocks           = fromIntegral $ H.fsNumBlocks stat
      , statAccessTime       = toPOSIXTime $ H.fsAccessTime stat
      , statModificationTime = undefined
      , statStatusChangeTime = undefined
      }


{-
data FileStat = FileStat { statEntryType :: EntryType
                         , statFileMode :: FileMode
                         , statLinkCount :: LinkCount
                         , statFileOwner :: UserID
                         , statFileGroup :: GroupID
                         , statSpecialDeviceID :: DeviceID
                         , statFileSize :: FileOffset
                         , statBlocks :: Integer
                         , statAccessTime :: EpochTime
                         , statModificationTime :: EpochTime
                         , statStatusChangeTime :: EpochTime
                         }
-}


halfsReadSymbolicLink :: HalfsCapable b t r l m =>
                         HalfsSpecific b r l m
                      -> FilePath
                      -> m (Either Errno FilePath)
halfsReadSymbolicLink (log, _fs) _fp = do 
  log $ "halfsReadSymbolicLink: Not Yet Implemented"
  return (Left eNOSYS)

halfsCreateDevice :: HalfsCapable b t r l m =>
                     HalfsSpecific b r l m
                  -> FilePath -> EntryType -> FileMode -> DeviceID
                  -> m Errno
halfsCreateDevice (log, _fs) _fp _etype _mode _devID = do
  log $ "halfsCreateDevice: Not Yet Implemented." -- TODO
  return eNOSYS

halfsCreateDirectory :: HalfsCapable b t r l m =>
                        HalfsSpecific b r l m
                     -> FilePath -> FileMode
                     -> m Errno
halfsCreateDirectory (log, _fs) _fp _mode = do
  log $ "halfsCreateDirectory: Not Yet Implemented." -- TODO
  return eNOSYS
         
halfsRemoveLink :: HalfsCapable b t r l m =>
                   HalfsSpecific b r l m
                -> FilePath
                -> m Errno
halfsRemoveLink (log, _fs) _fp = do
  log $ "halfsRemoveLink: Not Yet Implemented." -- TODO
  return eNOSYS
         
halfsRemoveDirectory :: HalfsCapable b t r l m =>
                        HalfsSpecific b r l m
                     -> FilePath
                     -> m Errno
halfsRemoveDirectory (log, _fs) _fp = do
  log $ "halfsRemoveDirectory: Not Yet Implemented." -- TODO
  return eNOSYS
         
halfsCreateSymbolicLink :: HalfsCapable b t r l m =>
                           HalfsSpecific b r l m
                        -> FilePath -> FilePath
                        -> m Errno
halfsCreateSymbolicLink (log, _fs) _src _dst = do
  log $ "halfsCreateSymbolicLink: Not Yet Implemented." -- TODO
  return eNOSYS
         
halfsRename :: HalfsCapable b t r l m =>
               HalfsSpecific b r l m
            -> FilePath -> FilePath
            -> m Errno
halfsRename (log, _fs) _old _new = do
  log $ "halfsRename: Not Yet Implemented." -- TODO
  return eNOSYS
         
halfsCreateLink :: HalfsCapable b t r l m =>
                   HalfsSpecific b r l m
                -> FilePath -> FilePath
                -> m Errno
halfsCreateLink (log, _fs) _src _dst = do
  log $ "halfsCreateLink: Not Yet Implemented." -- TODO
  return eNOSYS
         
halfsSetFileMode :: HalfsCapable b t r l m =>
                    HalfsSpecific b r l m
                 -> FilePath -> FileMode
                 -> m Errno
halfsSetFileMode (log, _fs) _fp _mode = do
  log $ "halfsSetFileMode: Not Yet Implemented." -- TODO
  return eNOSYS
         
halfsSetOwnerAndGroup :: HalfsCapable b t r l m =>
                         HalfsSpecific b r l m
                      -> FilePath -> UserID -> GroupID
                      -> m Errno
halfsSetOwnerAndGroup (log, _fs) _fp _uid _gid = do
  log $ "halfsSetOwnerAndGroup: Not Yet Implemented." -- TODO
  return eNOSYS
         
halfsSetFileSize :: HalfsCapable b t r l m =>
                    HalfsSpecific b r l m
                 -> FilePath -> FileOffset
                 -> m Errno
halfsSetFileSize (log, _fs) _fp _offset = do
  log $ "halfsSetFileSize: Not Yet Implemented." -- TODO
  return eNOSYS
         
halfsSetFileTimes :: HalfsCapable b t r l m =>
                     HalfsSpecific b r l m
                  -> FilePath -> EpochTime -> EpochTime
                  -> m Errno
halfsSetFileTimes (log, _fs) _fp _tm0 _tm1 = do
  log $ "halfsSetFileTimes: Not Yet Implemented." -- TODO
  return eNOSYS
         
halfsOpen :: HalfsCapable b t r l m =>
             HalfsSpecific b r l m             
          -> FilePath -> OpenMode -> OpenFileFlags
          -> m (Either Errno FileHandle)
halfsOpen (log, _fs) fp mode flags = do
  log $ "halfsOpen: fp = " ++ show fp ++ ", mode = " ++ show mode ++ ", flags = " ++ show flags
  return (Left eOK)

halfsRead :: HalfsCapable b t r l m =>
             HalfsSpecific b r l m
          -> FilePath -> FileHandle -> ByteCount -> FileOffset
          -> m (Either Errno BS.ByteString)
halfsRead (log, _fs) fp _fh byteCnt offset = do
  log $ "halfsRead: fp = " ++ show fp ++ ", byteCnt = " ++ show byteCnt ++ ", offset = " ++ show offset
  return (Left eOK)

halfsWrite :: HalfsCapable b t r l m =>
              HalfsSpecific b r l m
           -> FilePath -> FileHandle -> BS.ByteString -> FileOffset
           -> m (Either Errno ByteCount)
halfsWrite (log, _fs) _fp _fh _bytes _offset = do
  log $ "halfsWrite: Not Yet Implemented." -- TODO
  return (Left eNOSYS)

halfsGetFileSystemStats :: HalfsCapable b t r l m =>
                           HalfsSpecific b r l m
                        -> FilePath
                        -> m (Either Errno System.Fuse.FileSystemStats)
halfsGetFileSystemStats (log, fs) fp = do
  log $ "halfsGetFileSystemStats: fp = " ++ show fp
  x <- execOrErrno eINVAL id (fsstat fs)
  log $ "FileSystemStats: " ++ show x
  return (fss2fss `fmap` x)
  where
    fss2fss (FSS bs bc bf ba fc ff) = System.Fuse.FileSystemStats
      { fsStatBlockSize       = bs
      , fsStatBlockCount      = bc
      , fsStatBlocksFree      = bf
      , fsStatBlocksAvailable = ba
      , fsStatFileCount       = fc
      , fsStatFilesFree       = ff
      , fsStatMaxNameLength   = maxNameLength
      }

halfsFlush :: HalfsCapable b t r l m =>
              HalfsSpecific b r l m
           -> FilePath -> FileHandle
           -> m Errno
halfsFlush (log, _fs) _fp _fh = do
  log $ "halfsFlush: Not Yet Implemented." -- TODO
  return eNOSYS
         
halfsRelease :: HalfsCapable b t r l m =>
                HalfsSpecific b r l m
             -> FilePath -> FileHandle
             -> m ()
halfsRelease (log, _fs) _fp _fh = do
  log $ "halfsRelease: Not Yet Implemented." -- TODO
  return ()
         
halfsSynchronizeFile :: HalfsCapable b t r l m =>
                        HalfsSpecific b r l m
                     -> FilePath -> System.Fuse.SyncType
                     -> m Errno
halfsSynchronizeFile (log, _fs) _fp _syncType = do
  log $ "halfsSynchronizeFile: Not Yet Implemented." -- TODO
  return eNOSYS
         
halfsOpenDirectory :: HalfsCapable b t r l m =>
                      HalfsSpecific b r l m
                   -> FilePath
                   -> m Errno
halfsOpenDirectory (log, _fs) fp = do
  log $ "halfsOpenDirectory: fp = " ++ show fp
  return eOK

halfsReadDirectory :: HalfsCapable b t r l m =>  
                      HalfsSpecific b r l m
                   -> FilePath
                   -> m (Either Errno [(FilePath, FileStat)])
halfsReadDirectory (log, _fs) fp = do
  log $ "halfsReadDirectory: fp = " ++ show fp
  return (Left eOK)

halfsReleaseDirectory :: HalfsCapable b t r l m =>
                         HalfsSpecific b r l m
                      -> FilePath
                      -> m Errno
halfsReleaseDirectory (log, _fs) _fp = do
  log $ "halfsReleaseDirectory: Not Yet Implemented." -- TODO
  return eNOSYS
         
halfsSynchronizeDirectory :: HalfsCapable b t r l m =>
                             HalfsSpecific b r l m
                          -> FilePath -> System.Fuse.SyncType
                          -> m Errno
halfsSynchronizeDirectory (log, _fs) _fp _syncType = do
  log $ "halfsSynchronizeDirectory: Not Yet Implemented." -- TODO
  return eNOSYS
         
halfsAccess :: HalfsCapable b t r l m =>
               HalfsSpecific b r l m
            -> FilePath -> Int
            -> m Errno
halfsAccess (log, _fs) _fp _n = do
  log $ "halfsAccess: Not Yet Implemented." -- TODO
  return eNOSYS
         
halfsInit :: HalfsCapable b t r l m =>
             HalfsSpecific b r l m
          -> m ()
halfsInit (log, _fs) = do
  log $ "halfsInit: Not Yet Implemented." -- TODO
  return ()

halfsDestroy :: HalfsCapable b t r l m =>
                HalfsSpecific b r l m
             -> m ()
halfsDestroy (log, fs) = do
  log "halfsDestroy: Unmounting..." 
  exec $ unmount fs
  log "halfsDestroy: Shutting block device down..."        
  exec $ lift $ bdShutdown (hsBlockDev fs)
  log $ "halfsDestroy: Done."
  return ()

--------------------------------------------------------------------------------
-- Misc

logger :: Handle -> Logger IO
logger h s = do
  hPutStrLn h s 
  hFlush h
-- logger _ _ = return ()

exec :: Monad m => HalfsT m a -> m a
exec act =
  runHalfs act >>= \ea -> case ea of
    Left e  -> fail $ show e
    Right x -> return x

execOrErrno :: Monad m => Errno -> (a -> b) -> HalfsT m a -> m (Either Errno b)
execOrErrno en f act =
 runHalfs act >>= \ea -> case ea of
   Left _  -> return $ Left en
   Right x -> return $ Right (f x)

--------------------------------------------------------------------------------
-- Command line stuff

data Options = Options
  { optFileDev :: Maybe FilePath
  , optMemDev  :: Bool
  , optNumSecs :: Word64
  , optSecSize :: Word64
  }
  deriving (Show)

defOpts :: Options
defOpts = Options
  { optFileDev = Nothing
  , optMemDev  = True
  , optNumSecs = 512
  , optSecSize = 512
  } 

options :: [OptDescr (Options -> Options)]
options =
  [ Option ['m'] ["memdev"]
      (NoArg $ \opts -> opts{ optFileDev = Nothing, optMemDev = True })
      "use memory device"
  , Option ['f'] ["filedev"]
      (ReqArg (\f opts -> opts{ optFileDev = Just f, optMemDev = False })
              "PATH"
      )
      "use file-backed device"
  , Option ['n'] ["numsecs"]
      (ReqArg (\s0 opts -> let s1 = Prelude.read s0 in opts{ optNumSecs = s1 })
              "SIZE"
      )
      "number of sectors (ignored for filedevs)"
  , Option ['s'] ["secsize"]
      (ReqArg (\s0 opts -> let s1 = Prelude.read s0 in opts{ optSecSize = s1 })
              "SIZE"
      )
      "sector size in bytes (ignored for already-existing filedevs)"
  ]

--------------------------------------------------------------------------------
-- Instances for debugging

instance Show OpenMode where
  show ReadOnly  = "ReadOnly"
  show WriteOnly = "WriteOnly"
  show ReadWrite = "ReadWrite"

instance Show OpenFileFlags where
  show (OpenFileFlags append' exclusive' noctty' nonBlock' trunc') =
    "OpenFileFlags { append    = " ++ show append'    ++    
    "                exclusive = " ++ show exclusive' ++ 
    "                noctty    = " ++ show noctty'    ++    
    "                nonBlock  = " ++ show nonBlock'  ++  
    "                trunc     = " ++ show trunc'
